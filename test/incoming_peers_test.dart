import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:test/test.dart';
import 'package:torrent_task/src/piece/base_piece_selector.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Блокер E: приём входящих подключений и повторное подключение к адресу.
///
/// Главная поломка была не в «не переподключаемся», а в учёте входящих:
/// `_hookInPeer` регистрировал пира по `socket.address`/`socket.port` — это
/// НАША сторона (bind-адрес 0.0.0.0 и наш же слушающий порт), а не тот, кто
/// подключился. Счётчик входящих в TorrentTask заполнялся этим фиктивным
/// адресом один раз за всю жизнь задачи и никогда не освобождался: второе
/// входящее соединение закрывалось сразу. Для раздачи это ровно один качающий,
/// и то до первого обрыва.
void main() {
  group('Блокер E — входящие подключения', () {
    late Directory tmp;
    late StubTracker tracker;
    late TorrentTask task;
    late int seedPort;
    late Uint8List infoHash;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('incoming_');
      tracker = await StubTracker.start();
      final files = [MapEntry('book.mp3', pseudoBytes(40 * 1024, 4))];
      final model = buildTorrent(
        name: 'incoming-book',
        pieceLength: 16 * 1024,
        files: files,
        announces: [tracker.announceUrl],
        infoHashSeed: 31,
      );
      infoHash = model.infoHashBuffer!;
      await writeFiles(tmp, model, files);

      task = TorrentTask.newTask(model, tmp.path);
      final verified = await task.recheck();
      expect(verified, equals(model.pieces.length),
          reason: 'предусловие: сид полон, ему есть что раздавать');
      final map = await task.start();
      seedPort = map['tcp_socket'] as int;
    });

    tearDown(() async {
      await task.stop();
      await tracker.stop();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('два одновременных входящих подключения принимаются оба', () async {
      final a = await _leech(seedPort, infoHash);
      final b = await _leech(seedPort, infoHash);

      // ПРЕДУСЛОВИЕ: первое подключение действительно установилось — иначе
      // «оба живы» подтвердилось бы на двух мёртвых сокетах.
      expect(await a.handshaked, isTrue,
          reason: 'предусловие: первый качающий получил handshake');

      expect(await b.handshaked, isTrue,
          reason: 'второй качающий не должен закрываться сразу: раньше слот '
              'входящих занимался первым и не освобождался');
      expect(task.connectedPeersNumber, equals(2),
          reason: 'оба входящих пира обязаны считаться активными '
              '(равенство Peer учитывает порт, а не только IP)');

      await a.close();
      await b.close();
    });

    test('слот входящего освобождается при обрыве, а не течёт', () async {
      // Циклов больше, чем лимит подключений с одного IP: если слот при
      // обрыве не освобождается, до последнего круга мы не доедем. Лимит
      // берём из самого кода — сверять копию константы с копией бессмысленно.
      final rounds = MAX_IN_PEERS_PER_IP + 1;
      for (var i = 0; i < rounds; i++) {
        final leech = await _leech(seedPort, infoHash);
        expect(await leech.handshaked, isTrue,
            reason: 'подключение №${i + 1} из $rounds должно приниматься: '
                'после обрыва слот входящего обязан освобождаться');
        await leech.close();
        // Дать сиду переварить разрыв и освободить слот.
        await _waitFor(() => task.connectedPeersNumber == 0);
        expect(task.connectedPeersNumber, equals(0),
            reason: 'предусловие круга ${i + 1}: сид увидел разрыв');
      }
    });
  });

  group('Блокер E — пауза перед повторным исходящим подключением', () {
    late Directory tmp;
    late PeersManager manager;
    late int deadPort;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('reconnect_');
      final files = [MapEntry('book.mp3', pseudoBytes(20 * 1024, 8))];
      final model = buildTorrent(
        name: 'reconnect-book',
        pieceLength: 16 * 1024,
        files: files,
        infoHashSeed: 41,
      );
      await writeFiles(tmp, model, files);
      final stateFile = await StateFile.getStateFile(tmp.path, model);
      final pieceManager = PieceManager.createPieceManager(
          // Тест про переподключения, куски здесь не докачиваются: проверка
          // SHA1 отключена явно.
          BasePieceSelector(), model, stateFile.bitfield,
          verifier: null);
      final fileManager =
          await DownloadFileManager.createFileManager(model, tmp.path, stateFile);
      manager = PeersManager(
          '-DT0201-testtestteste', pieceManager, pieceManager, fileManager, model);
      // Сжимаем паузу: проверяем правило, а не 15 секунд ожидания.
      manager.reconnectBaseDelay = const Duration(milliseconds: 300);
      manager.reconnectMaxDelay = const Duration(seconds: 1);

      // Порт, который гарантированно никто не слушает: занимаем и отпускаем.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      deadPort = probe.port;
      await probe.close();
    });

    tearDown(() async {
      await manager.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('после провала подключения адрес придерживается, потом снова доступен',
        () async {
      final dead = CompactAddress(InternetAddress.loopbackIPv4, deadPort);

      manager.addNewPeerAddress(dead);
      // ПРЕДУСЛОВИЕ: попытка действительно была сделана и провалилась —
      // иначе «адрес придержан» ничего не значит.
      expect(manager.peersNumber, equals(1),
          reason: 'предусловие: первая попытка подключения принята в работу');
      await _waitFor(() => manager.peersNumber == 0);
      expect(manager.peersNumber, equals(0),
          reason: 'предусловие: подключение провалилось и адрес отпущен');

      // Сразу же повторно — должны придержать.
      manager.addNewPeerAddress(dead);
      expect(manager.peersNumber, equals(0),
          reason: 'в паузе после провала к тому же адресу не ходим');

      await Future.delayed(const Duration(milliseconds: 500));
      manager.addNewPeerAddress(dead);
      expect(manager.peersNumber, equals(1),
          reason: 'по истечении паузы адрес снова доступен для подключения');
    });
  });
}

/// Минимальный «качающий»: подключается к сиду, шлёт handshake и ждёт ответный.
class _Leech {
  final Socket socket;
  final Completer<bool> _hs = Completer<bool>();

  _Leech(this.socket, Uint8List infoHash) {
    final buf = <int>[];
    socket.listen((data) {
      buf.addAll(data);
      if (buf.length >= 68 && !_hs.isCompleted) _hs.complete(true);
    }, onError: (_) {
      if (!_hs.isCompleted) _hs.complete(false);
    }, onDone: () {
      if (!_hs.isCompleted) _hs.complete(false);
    });
    socket.add(_handshake(infoHash));
  }

  Future<bool> get handshaked =>
      _hs.future.timeout(const Duration(seconds: 10), onTimeout: () => false);

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
    socket.destroy();
  }
}

Future<_Leech> _leech(int seedPort, Uint8List infoHash) async {
  // Не loopback: TorrentTask намеренно закрывает подключения с 127.0.0.1
  // (защита от соединения с самим собой), поэтому идём через реальный адрес
  // интерфейса — как это делает настоящий клиент в локальной сети.
  final s = await Socket.connect(await _localAddress(), seedPort);
  return _Leech(s, infoHash);
}

InternetAddress? _cached;

Future<InternetAddress> _localAddress() async {
  if (_cached != null) return _cached!;
  final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
  for (final i in ifs) {
    for (final a in i.addresses) {
      if (!a.isLoopback) {
        _cached = a;
        return a;
      }
    }
  }
  throw StateError('нет не-loopback IPv4 адреса — тесту не через что ходить');
}

List<int> _handshake(Uint8List infoHash) {
  final m = <int>[];
  m.addAll(HAND_SHAKE_HEAD);
  m.addAll(RESERVED);
  m.addAll(infoHash);
  m.addAll('-AR1370-remoteremot'.codeUnits);
  m.add(0x21);
  return m;
}

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future.delayed(const Duration(milliseconds: 20));
  }
}
