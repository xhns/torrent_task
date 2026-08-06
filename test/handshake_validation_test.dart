import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Находка сверх списка блокеров: поток, начинающийся НЕ с BitTorrent
/// handshake, обязан приводить к немедленному закрытию соединения.
///
/// aria2c (как и qBittorrent) начинает исходящее подключение с MSE/PE —
/// шифрованного рукопожатия. Мы его не поддерживаем, но и не закрывались:
/// байты DH-ключа уходили в разбор сообщений как длина, и соединение висело до
/// 150-секундного таймаута тишины. Инициатор переходит на открытое
/// рукопожатие только по ОШИБКЕ сокета — её не было, и обмен вставал намертво.
///
/// Замерено на живом стенде: по входящему соединению за 100 секунд не ушло ни
/// байта; после фикса те же 57 МиБ уехали за 10 секунд (9.3 МБ/с).
void main() {
  group('Рукопожатие — мусор в начале потока закрывает соединение', () {
    late Directory tmp;
    late StubTracker tracker;
    late TorrentTask task;
    late int seedPort;
    late Uint8List infoHash;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('handshake_');
      tracker = await StubTracker.start();
      final files = [MapEntry('book.mp3', pseudoBytes(40 * 1024, 6))];
      final model = buildTorrent(
        name: 'handshake-book',
        pieceLength: 16 * 1024,
        files: files,
        announces: [tracker.announceUrl],
        infoHashSeed: 53,
      );
      infoHash = model.infoHashBuffer!;
      await writeFiles(tmp, model, files);
      task = TorrentTask.newTask(model, tmp.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      await task.recheck();
      final map = await task.start();
      seedPort = map['tcp_socket'] as int;
    });

    tearDown(() async {
      await task.stop();
      await tracker.stop();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('MSE-подобный мусор закрывается, а не висит', () async {
      final s = await Socket.connect(await localAddress(), seedPort);
      final closed = Completer<bool>();
      s.listen((_) {}, onError: (_) {
        if (!closed.isCompleted) closed.complete(true);
      }, onDone: () {
        if (!closed.isCompleted) closed.complete(true);
      });

      // Так выглядит начало MSE: 96 байт публичного ключа Диффи-Хеллмана.
      // Первый байт заведомо не 19 — сигнатуры BitTorrent тут нет.
      final dhLike = Uint8List.fromList(
          List<int>.generate(96, (i) => (i * 37 + 11) & 0xff)..[0] = 0xA7);
      s.add(dhLike);
      await s.flush();

      final wasClosed = await closed.future
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      s.destroy();

      expect(wasClosed, isTrue,
          reason: 'соединение с не-BitTorrent потоком должно закрываться '
              'сразу: инициатор ждёт ошибку, чтобы повторить открытым '
              'рукопожатием');
    });

    test('нормальное рукопожатие по-прежнему принимается', () async {
      // ПРЕДУСЛОВИЕ к проверке выше: закрытие должно бить только по мусору.
      // Если бы фикс рубил всё подряд, этот тест покраснел бы.
      final s = await Socket.connect(await localAddress(), seedPort);
      final gotHandshake = Completer<bool>();
      final buf = <int>[];
      s.listen((d) {
        buf.addAll(d);
        if (buf.length >= 68 && !gotHandshake.isCompleted) {
          gotHandshake.complete(true);
        }
      }, onError: (_) {
        if (!gotHandshake.isCompleted) gotHandshake.complete(false);
      }, onDone: () {
        if (!gotHandshake.isCompleted) gotHandshake.complete(false);
      });

      final m = <int>[
        ...HAND_SHAKE_HEAD,
        ...RESERVED,
        ...infoHash,
        ...'-AR1370-remoteremot'.codeUnits,
        0x21,
      ];
      s.add(m);
      await s.flush();

      final ok = await gotHandshake.future
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      s.destroy();
      expect(ok, isTrue,
          reason: 'настоящее рукопожатие обязано получать ответ');
    });

    test('рукопожатие, приходящее по байтам, не рвётся на полпути', () async {
      // Сигнатура длиннее одного TCP-сегмента не бывает, но дробление потока
      // законно: проверка не должна срабатывать на неполном префиксе.
      final s = await Socket.connect(await localAddress(), seedPort);
      final gotHandshake = Completer<bool>();
      final buf = <int>[];
      s.listen((d) {
        buf.addAll(d);
        if (buf.length >= 68 && !gotHandshake.isCompleted) {
          gotHandshake.complete(true);
        }
      }, onError: (_) {
        if (!gotHandshake.isCompleted) gotHandshake.complete(false);
      }, onDone: () {
        if (!gotHandshake.isCompleted) gotHandshake.complete(false);
      });

      final m = <int>[
        ...HAND_SHAKE_HEAD,
        ...RESERVED,
        ...infoHash,
        ...'-AR1370-remoteremot'.codeUnits,
        0x21,
      ];
      for (var i = 0; i < m.length; i += 7) {
        s.add(m.sublist(i, i + 7 > m.length ? m.length : i + 7));
        await s.flush();
        await Future.delayed(const Duration(milliseconds: 5));
      }

      final ok = await gotHandshake.future
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      s.destroy();
      expect(ok, isTrue,
          reason: 'побайтно приходящее рукопожатие не должно приниматься за '
              'мусор, пока префикс совпадает');
    });
  });
}

InternetAddress? _cached;

Future<InternetAddress> localAddress() async {
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
