import 'dart:async';
import 'dart:io';

import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:test/test.dart';
import 'package:torrent_task/src/lsd/lsd.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Блокер C: пир, найденный через Local Service Discovery (BEP 14), обязан
/// доехать до менеджера пиров. Цепочка была порвана в трёх местах сразу:
///   1. сокет не вступал в мультикаст-группу — анонсы соседей не приходили;
///   2. сравнение первой строки шло с `\r\n`, которого после `split` нет, —
///      любой анонс отбрасывался до разбора полей;
///   3. обработчик в TorrentTask только печатал отладочную строку.
void main() {
  // Свой порт группы: общесистемный 6771 занят настоящими BitTorrent-клиентами
  // и параллельными прогонами, и unicast-датаграмму на него SO_REUSEPORT отдаёт
  // произвольному слушателю.
  const testGroupPort = 47713;
  final ourHash = 'a' * 40;
  final foreignHash = 'b' * 40;

  group('LSD — разбор анонса', () {
    late LSD lsd;
    late RawDatagramSocket sender;
    late List<(CompactAddress, String)> got;

    setUp(() async {
      got = [];
      lsd = LSD(ourHash, 'peer-listener-0001', groupPort: testGroupPort);
      lsd.port = 6881;
      lsd.onLSDPeer((a, h) => got.add((a, h)));
      lsd.start();
      sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // Дать сокету подняться (start() асинхронный и не возвращает Future).
      await _waitFor(() => !lsd.isClosed, timeout: Duration(milliseconds: 200));
      await Future.delayed(const Duration(milliseconds: 200));
    });

    tearDown(() async {
      lsd.close();
      sender.close();
    });

    test('корректный анонс доходит до обработчика', () async {
      _send(sender, testGroupPort,
          _announce(port: 51413, infoHash: ourHash, cookie: 'dt-client-other'));
      await _waitFor(() => got.isNotEmpty);

      expect(got, hasLength(1),
          reason: 'валидный BT-SEARCH обязан породить событие о пире');
      expect(got.first.$1.port, equals(51413),
          reason: 'порт пира берётся из поля Port анонса, а не из источника');
      expect(got.first.$2, equals(ourHash));
    });

    test('собственный анонс отсеивается по cookie (BEP 14)', () async {
      // Наш же cookie — так выглядит наша датаграмма, вернувшаяся из группы.
      _send(
          sender,
          testGroupPort,
          _announce(
              port: 51413,
              infoHash: ourHash,
              cookie: 'dt-clientpeer-listener-0001'));
      await Future.delayed(const Duration(milliseconds: 400));

      // ПРЕДУСЛОВИЕ: тот же самый анонс с чужим cookie проходит — значит путь
      // рабочий и молчание выше вызвано именно фильтром, а не поломкой разбора.
      _send(sender, testGroupPort,
          _announce(port: 51414, infoHash: ourHash, cookie: 'dt-client-other'));
      await _waitFor(() => got.isNotEmpty);

      expect(got.map((e) => e.$1.port), equals([51414]),
          reason: 'свой анонс игнорируется, чужой — принимается');
    });

    test('чужая первая строка игнорируется', () async {
      _send(sender, testGroupPort,
          'GET / HTTP/1.1\r\nPort: 51413\r\nInfohash: $ourHash\r\n\r\n');
      await Future.delayed(const Duration(milliseconds: 400));
      expect(got, isEmpty);
    });

    test('мультикаст: два LSD в группе видят анонсы друг друга', () async {
      // Прямая проверка joinMulticast: без вступления в группу датаграмма,
      // отправленная на групповой адрес, до слушателя не доходит вовсе.
      final other = LSD(ourHash, 'peer-sender-0002', groupPort: testGroupPort);
      other.port = 6882;
      other.start();
      addTearDown(other.close);

      await _waitFor(() => got.isNotEmpty, timeout: Duration(seconds: 5));

      expect(got, isNotEmpty,
          reason: 'групповой анонс соседа обязан дойти — иначе LSD мёртв');
      expect(got.first.$1.port, equals(6882));
    });
  });

  group('Блокер C — LSD-пир доезжает до задачи', () {
    late Directory tmp;
    late StubTracker tracker;
    late ServerSocket fakePeer;
    late ServerSocket otherFakePeer;
    late RawDatagramSocket sender;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lsd_task_');
      tracker = await StubTracker.start();
      // Живой слушатель, чтобы подключение к «найденному пиру» состоялось и
      // пир не отвалился сразу по TCPConnectException.
      fakePeer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      fakePeer.listen((s) {});
      otherFakePeer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      otherFakePeer.listen((s) {});
      sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    });

    tearDown(() async {
      sender.close();
      await fakePeer.close();
      await otherFakePeer.close();
      await tracker.stop();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('анонс с нашим infohash добавляет пира, с чужим — нет', () async {
      final files = [MapEntry('book.mp3', pseudoBytes(20 * 1024, 3))];
      final model = buildTorrent(
        name: 'lsd-book',
        pieceLength: 16 * 1024,
        files: files,
        announces: [tracker.announceUrl],
        infoHashSeed: 11,
      );
      await writeFiles(tmp, model, files);

      final task = TorrentTask.newTask(model, tmp.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      await task.recheck();
      await task.start();
      addTearDown(task.stop);
      await Future.delayed(const Duration(milliseconds: 300));

      expect(task.allPeersNumber, equals(0),
          reason: 'до анонсов задача не знает ни одного пира');

      // Сначала СВОЙ infohash. Заодно это предусловие для отрицательной
      // проверки ниже: LSD-сокет задачи уже поднят и вступил в группу, значит
      // молчание на чужой анонс будет означать фильтр, а не «не доехало».
      // (Порядок важен: обратный порядок давал зелёный тест при полностью
      // снятом фильтре — датаграмма терялась, пока сокет ещё поднимался.)
      _send(
          sender,
          LSD.LSD_PORT,
          _announce(
              port: fakePeer.port,
              infoHash: model.infoHash!,
              cookie: 'dt-client-stranger'));
      await _waitFor(() => task.allPeersNumber > 0,
          timeout: const Duration(seconds: 5));
      expect(task.allPeersNumber, equals(1),
          reason: 'пир из LSD обязан попасть в addNewPeerAddress');

      // Теперь чужой торрент с ДРУГОГО адреса: мультикаст-сокет LSD принимает
      // анонсы всей сети, и подключаться к чужому сварму мы не должны.
      _send(
          sender,
          LSD.LSD_PORT,
          _announce(
              port: otherFakePeer.port,
              infoHash: foreignHash,
              cookie: 'dt-client-stranger'));
      await Future.delayed(const Duration(seconds: 1));
      expect(task.allPeersNumber, equals(1),
          reason: 'анонс чужого infohash не должен добавлять пира');
    });
  });
}

/// Отправка на групповой адрес: мультикаст доставляется ВСЕМ вступившим в
/// группу сокетам, поэтому чужие задачи в параллельных прогонах у нас
/// датаграмму не перехватят (в отличие от unicast + SO_REUSEPORT).
void _send(RawDatagramSocket sock, int port, String message) {
  sock.send(message.codeUnits, LSD.LSD_HOST, port);
}

String _announce(
        {required int port, required String infoHash, required String cookie}) =>
    'BT-SEARCH * HTTP/1.1\r\n'
    'Host: ${LSD.LSD_HOST_ADDRESS}:$port\r\n'
    'Port: $port\r\n'
    'Infohash: $infoHash\r\n'
    'cookie: $cookie\r\n\r\n\r\n';

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future.delayed(const Duration(milliseconds: 20));
  }
}
