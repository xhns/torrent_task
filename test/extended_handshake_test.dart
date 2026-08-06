import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bencode_dart/bencode_dart.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Блокер D: наш слушающий TCP-порт обязан уходить пиру полем `p` extended
/// handshake (BEP 10).
///
/// Без него пир, к которому подключились МЫ, знает только наш исходящий
/// эфемерный порт: он не переподключится к нам после обрыва и не расскажет о
/// нас через PEX. В замере aria2 показывал для нас tcpPort=0.
void main() {
  group('Блокер D — extended handshake', () {
    late ServerSocket server;
    late Socket remoteSide;
    late Peer peer;
    final infoHash = Uint8List.fromList(List<int>.generate(20, (i) => i));
    const ourListeningPort = 51999;

    late Completer<Map> extended;

    Future<void> setUpPeer({required int localPort}) async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      remoteSide =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final ourSide = await accepted;

      extended = Completer<Map>();
      final buf = <int>[];
      remoteSide.listen((data) {
        buf.addAll(data);
        final m = _takeExtendedHandshake(buf);
        if (m != null && !extended.isCompleted) extended.complete(m);
      });

      peer = Peer.newTCPPeer(
        '-DT0201-testtestteste',
        CompactAddress(InternetAddress.loopbackIPv4, remoteSide.port),
        infoHash,
        16,
        ourSide,
        localPort: localPort,
      );
      await peer.connect();
      // Удалённая сторона объявляет поддержку extension protocol — иначе мы по
      // протоколу вообще не обязаны слать extended handshake.
      remoteSide.add(_handshake(infoHash, extendedBit: true));
      await remoteSide.flush();
    }

    tearDown(() async {
      await peer.dispose('test over');
      await remoteSide.close();
      await server.close();
    });

    test('поле p несёт наш слушающий порт', () async {
      await setUpPeer(localPort: ourListeningPort);
      final d = await extended.future.timeout(const Duration(seconds: 10),
          onTimeout: () => throw StateError(
              'extended handshake не пришёл — проверять `p` не в чем'));

      // ПРЕДУСЛОВИЕ: это действительно extended handshake, а не пустой словарь;
      // иначе отсутствие/наличие `p` ничего не значит.
      expect(d['reqq'], isNotNull,
          reason: 'предусловие: разобран настоящий extended handshake');

      expect(d['p'], equals(ourListeningPort),
          reason: 'пир обязан узнать порт, на который к нам можно постучаться');
    });

    test('reqq объявляется тем же значением, что мы держим', () async {
      await setUpPeer(localPort: ourListeningPort);
      final d = await extended.future.timeout(const Duration(seconds: 10));
      // Источник один: peer.reqq — и лимит очереди, и объявленное значение.
      expect(d['reqq'], equals(peer.reqq));
    });

    test('неизвестный порт не превращается в лживый p=0', () async {
      await setUpPeer(localPort: 0);
      final d = await extended.future.timeout(const Duration(seconds: 10));
      expect(d['reqq'], isNotNull,
          reason: 'предусловие: разобран настоящий extended handshake');
      expect(d.containsKey('p'), isFalse,
          reason: 'p=0 неотличим от «порт 0» — лучше не слать поле вовсе');
    });
  });

  // Проверки выше строят Peer напрямую, поэтому не увидели бы, если бы порт
  // просто не доехал из задачи. Здесь — вся цепочка
  // TorrentTask -> PeersManager -> Peer на живых сокетах.
  group('Блокер D — порт доезжает из задачи до пира', () {
    late Directory tmp;
    late StubTracker tracker;
    late ServerSocket fakePeer;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ext_hs_task_');
      tracker = await StubTracker.start();
      fakePeer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await fakePeer.close();
      await tracker.stop();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('пир, к которому подключились мы, узнаёт наш слушающий порт',
        () async {
      final files = [MapEntry('book.mp3', pseudoBytes(20 * 1024, 9))];
      final model = buildTorrent(
        name: 'ext-hs-book',
        pieceLength: 16 * 1024,
        files: files,
        announces: [tracker.announceUrl],
        infoHashSeed: 23,
      );
      await writeFiles(tmp, model, files);

      final got = Completer<Map>();
      fakePeer.listen((s) {
        final buf = <int>[];
        var answered = false;
        s.listen((data) {
          buf.addAll(data);
          // Отвечаем handshake'ом с extension-битом ровно один раз — иначе мы
          // подсунем собеседнику второй handshake посреди потока сообщений.
          if (!answered && buf.length >= 68) {
            answered = true;
            try {
              s.add(_handshake(model.infoHashBuffer!, extendedBit: true));
            } catch (_) {}
          }
          final m = _takeExtendedHandshake(buf);
          if (m != null && !got.isCompleted) got.complete(m);
        }, onError: (_) {}, onDone: () {});
      });

      final task = TorrentTask.newTask(model, tmp.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      await task.recheck();
      final map = await task.start();
      addTearDown(task.stop);
      final ourPort = map['tcp_socket'] as int;

      task.addPeer(
          CompactAddress(InternetAddress.loopbackIPv4, fakePeer.port));

      final d = await got.future.timeout(const Duration(seconds: 15),
          onTimeout: () =>
              throw StateError('пир не получил от нас extended handshake'));

      expect(d['reqq'], isNotNull,
          reason: 'предусловие: разобран настоящий extended handshake');
      expect(d['p'], equals(ourPort),
          reason: 'порт из TorrentTask.start() должен доехать до пира');
    });
  });
}

/// Вытащить из потока байт первый extended handshake (id=20, ext id=0).
/// Возвращает разобранный bencode-словарь или null, если ещё не собрался.
Map? _takeExtendedHandshake(List<int> buf) {
  var i = 0;
  // Пропустить входящий BT-handshake, если он есть.
  if (buf.isNotEmpty && buf[0] == 19 && buf.length >= 68) i = 68;
  while (buf.length - i >= 4) {
    final len = (buf[i] << 24) | (buf[i + 1] << 16) | (buf[i + 2] << 8) | buf[i + 3];
    if (buf.length - i - 4 < len) return null;
    if (len > 0 && buf[i + 4] == ID_EXTENDED && len > 2 && buf[i + 5] == 0) {
      final payload = Uint8List.fromList(buf.sublist(i + 6, i + 4 + len));
      final decoded = decode(payload);
      return decoded is Map ? _stringifyKeys(decoded) : null;
    }
    i += 4 + len;
  }
  return null;
}

/// bencode_dart отдаёт ключи как Uint8List — приводим к строкам.
Map<String, dynamic> _stringifyKeys(Map raw) {
  final out = <String, dynamic>{};
  raw.forEach((k, v) {
    final key = k is String ? k : String.fromCharCodes(k as List<int>);
    out[key] = v;
  });
  return out;
}

List<int> _handshake(Uint8List infoHash, {bool extendedBit = false}) {
  final m = <int>[];
  m.addAll(HAND_SHAKE_HEAD);
  final reserved = List<int>.from(RESERVED);
  if (extendedBit) reserved[5] |= 0x10;
  m.addAll(reserved);
  m.addAll(infoHash);
  m.addAll('-AR1370-remoteremot'.codeUnits);
  m.add(0x21);
  return m;
}
