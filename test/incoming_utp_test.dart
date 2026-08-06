import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';
import 'package:utp/utp.dart';

import 'seeding_support.dart';

/// Приём входящих uTP-соединений.
///
/// `ServerUTPSocket.bind` и обработчик входящих в `TorrentTask` были
/// закомментированы: исходящий uTP работал, входящий — нет. Для пользователя за
/// NAT это половина потерянных шансов: у части провайдеров и роутеров UDP
/// проходит там, где входящее TCP-соединение не устанавливается.
void main() {
  late Directory tmp;
  late TorrentTask task;
  late Uint8List infoHash;
  late int seedPort;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('incoming_utp_');
    final files = [MapEntry('book.mp3', pseudoBytes(32 * 1024, 9))];
    // infoHashSeed обязан быть УНИКАЛЬНЫМ по всему каталогу тестов: infohash в
    // [buildTorrent] выводится только из него, LSD-группа 6771 общая на всю
    // машину, а `dart test` гоняет файлы параллельными процессами. При
    // совпадении seed (было с handshake_validation_test, seed 53) чужая задача
    // находила нас по LSD и открывала настоящее ВХОДЯЩЕЕ TCP-соединение —
    // счётчики достижимости ниже разъезжались через раз.
    final model = buildTorrent(
      name: 'utp-book',
      pieceLength: 16 * 1024,
      files: files,
      infoHashSeed: 57,
    );
    infoHash = model.infoHashBuffer!;
    await writeFiles(tmp, model, files);

    task = TorrentTask.newTask(model, tmp.path,
        listenPort: kEphemeralListenPort,
        enableUtp: true,
        enablePortMapping: false);
    final verified = await task.recheck();
    expect(verified, equals(model.pieces.length),
        reason: 'предусловие: сид полон, ему есть что раздавать');
    final map = await task.start();
    seedPort = map['utp_socket'] as int;
    // ПРЕДУСЛОВИЕ: uTP-слушатель действительно поднялся. Без него тест ниже
    // «не смог подключиться» ничего бы не доказывал.
    expect(seedPort, greaterThan(0),
        reason: 'предусловие: приём uTP слушает настоящий UDP-порт');
  });

  tearDown(() async {
    await task.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('входящий uTP-пир принимается и получает handshake', () async {
    final client = UTPSocketClient();
    try {
      final socket =
          await client.connect(await _localAddress(), seedPort);
      expect(socket, isNotNull,
          reason: 'предусловие: uTP-соединение с сидом установилось');

      final handshaked = Completer<bool>();
      final buf = <int>[];
      socket!.listen((data) {
        buf.addAll(data);
        if (buf.length >= 68 && !handshaked.isCompleted) {
          handshaked.complete(true);
        }
      }, onError: (_) {
        if (!handshaked.isCompleted) handshaked.complete(false);
      }, onDone: () {
        if (!handshaked.isCompleted) handshaked.complete(false);
      });
      socket.add(_handshake(infoHash));

      final ok = await handshaked.future
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      expect(ok, isTrue,
          reason: 'сид обязан ответить handshake на входящий uTP так же, '
              'как отвечает на входящий TCP');

      // Первые 20 байт handshake — фиксированный заголовок протокола: если
      // ответ пришёл, но это не BitTorrent, тест выше был бы зелёным впустую.
      expect(buf[0], equals(19), reason: 'pstrlen BitTorrent handshake');
      expect(String.fromCharCodes(buf.sublist(1, 20)),
          equals('BitTorrent protocol'));
      // Байты 28..47 handshake — infohash: подтверждаем, что ответили именно
      // по нашему торренту.
      expect(buf.sublist(28, 48), equals(infoHash));

      await _waitFor(() => task.reachability.incomingUtpConnections > 0);
      expect(task.reachability.incomingUtpConnections, greaterThan(0),
          reason: 'входящий uTP обязан попасть в диагностику достижимости');
      expect(task.reachability.incomingTcpConnections, equals(0),
          reason: 'соединение было uTP, а не TCP — счётчики не должны '
              'сваливаться в одну кучу');
    } finally {
      await client.close();
    }
  });

  test('входящий uTP-пир виден задаче как подключённый пир', () async {
    final client = UTPSocketClient();
    try {
      final socket = await client.connect(await _localAddress(), seedPort);
      expect(socket, isNotNull, reason: 'предусловие: соединение установилось');
      socket!.listen((_) {}, onError: (_) {}, onDone: () {});
      socket.add(_handshake(infoHash));

      await _waitFor(() => task.connectedPeersNumber > 0);
      expect(task.connectedPeersNumber, greaterThan(0),
          reason: 'входящий uTP заводится обычным пиром, а не отдельной '
              'сущностью');
      expect(task.utpPeerCount, greaterThan(0),
          reason: 'пир обязан числиться именно uTP-пиром: ось транспорта '
              'нагружена (проброс порта и диагностика смотрят на неё)');
    } finally {
      await client.close();
    }
  });
}

InternetAddress? _cached;

/// Не loopback: [TorrentTask] намеренно закрывает соединения с 127.0.0.1
/// (защита от подключения к самому себе) — и для TCP, и для uTP.
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
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future.delayed(const Duration(milliseconds: 20));
  }
}
