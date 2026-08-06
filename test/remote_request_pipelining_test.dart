import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:test/test.dart';
import 'package:torrent_task/src/peer/peer.dart';

/// Блокер B: пачка запросов глубже нашего reqq не должна убивать соединение.
///
/// Раньше `_processRemoteRequest` при `_remoteRequestBuffer.length > reqq`
/// звал `dispose()`. С дефолтом reqq=100 это рвало передачу любому взрослому
/// клиенту: aria2c выдаёт пачкой ~192 запроса, и раздача обрывалась на 86%.
///
/// Тест поднимает настоящую TCP-пару, отдаёт наш конец в [Peer.newTCPPeer] и
/// пишет в него сырые сообщения протокола со стороны «удалённого клиента».
void main() {
  group('Блокер B — глубокий пайплайн входящих запросов', () {
    late ServerSocket server;
    late Socket remoteSide;
    late Socket ourSide;
    late Peer peer;

    final infoHash = Uint8List.fromList(List<int>.generate(20, (i) => i));

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      remoteSide =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      ourSide = await accepted;

      peer = Peer.newTCPPeer(
        '-DT0201-testtestteste',
        CompactAddress(InternetAddress.loopbackIPv4, remoteSide.port),
        infoHash,
        64,
        ourSide,
      );
      await peer.connect();
      // Нас никто не choke'ает: запросы кладутся в очередь, а не отбрасываются
      // по правилу choke.
      peer.chokeRemote = false;
    });

    tearDown(() async {
      await peer.dispose('test over');
      await remoteSide.close();
      await server.close();
    });

    test('reqq по умолчанию рассчитан на пайплайн живых клиентов', () {
      // aria2c в замере выдавал 192 запроса одной пачкой; libtorrent держит
      // столько же и больше. Значение проверяем тем же числом, что уходит в
      // extended handshake, — источник один.
      expect(peer.reqq, greaterThanOrEqualTo(192),
          reason: 'reqq ниже пайплайна реальных клиентов = обрывы на середине');
    });

    test('192 запроса пачкой: ничего не отброшено, соединение живо', () async {
      remoteSide.add(_handshake(infoHash));
      const burst = 192;
      for (var i = 0; i < burst; i++) {
        remoteSide.add(_request(i ~/ 4, (i % 4) * 16384, 16384));
      }
      await remoteSide.flush();

      await _waitFor(() => peer.remoteRequestbuffer.length >= burst);

      // ПРЕДУСЛОВИЕ: пачка действительно превышает то, что раньше считалось
      // допустимым (старый дефолт reqq=100). Без этого тест зеленел бы на
      // пачке, которая и до фикса проходила.
      expect(burst, greaterThan(100),
          reason: 'предусловие: пачка должна превышать старый лимит reqq=100');

      expect(peer.isDisposed, isFalse,
          reason: 'глубокий пайплайн — не повод рвать связь');
      expect(peer.remoteRequestbuffer.length, equals(burst),
          reason: 'все запросы в пределах reqq обязаны встать в очередь');
    });

    test('сверх reqq лишнее отбрасывается, но соединение остаётся живым',
        () async {
      remoteSide.add(_handshake(infoHash));
      final over = peer.reqq + 50;
      for (var i = 0; i < over; i++) {
        remoteSide.add(_request(i ~/ 4, (i % 4) * 16384, 16384));
      }
      await remoteSide.flush();

      await _waitFor(() => peer.remoteRequestbuffer.length >= peer.reqq);
      // Дать шанс лишним 50 запросам доехать и быть обработанными.
      await Future.delayed(const Duration(milliseconds: 300));

      // ПРЕДУСЛОВИЕ: пачка действительно переполняет заявленную нами глубину —
      // иначе проверка «переполнение не рвёт связь» прошла бы по пути, где
      // переполнения не было.
      expect(over, greaterThan(peer.reqq),
          reason: 'предусловие: запросов послано больше, чем reqq');
      expect(peer.isDisposed, isFalse,
          reason: 'превышение reqq отбрасывает лишнее, но не рвёт соединение');
      expect(peer.remoteRequestbuffer.length, equals(peer.reqq),
          reason: 'очередь ограничена reqq конструктивно: расти ей некуда, '
              'поэтому «буфер растёт неограниченно» недостижимо');
    });
  });
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

List<int> _request(int index, int begin, int length) {
  final m = Uint8List(17);
  final v = ByteData.view(m.buffer);
  v.setUint32(0, 13, Endian.big);
  m[4] = ID_REQUEST;
  v.setUint32(5, index, Endian.big);
  v.setUint32(9, begin, Endian.big);
  v.setUint32(13, length, Endian.big);
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
