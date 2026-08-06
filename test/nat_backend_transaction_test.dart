import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:torrent_task/src/nat/nat_backend.dart';
import 'package:torrent_task/src/nat/nat_pmp.dart';
import 'package:torrent_task/src/nat/nat_udp.dart';
import 'package:torrent_task/src/nat/pcp.dart';

/// Бэкенды NAT-PMP/PCP целиком — против ПОДСТАВНОГО шлюза на loopback.
///
/// Разбор байтов покрыт отдельно (nat_pmp_test/pcp_test), но чистые функции
/// ничего не говорят о том, ЧЕЙ ответ бэкенд согласится принять. Три оси здесь
/// нагружены, и каждая проверяется мутацией:
///
/// * протокол — TCP и UDP маппятся по одному сокету, и ответ на чужой запрос
///   подсунул бы наружу неверный внешний порт;
/// * nonce у PCP — то же самое, только опознание идёт по нему;
/// * адрес источника — RFC 6886 §3.1 и RFC 6887 §8.1 требуют игнорировать
///   пакеты не от того, кого спрашивали, иначе любой сосед по LAN назначает
///   нам «внешний адрес».
///
/// Всё на 127.0.0.0/8, наружу не ходит.
void main() {
  group('NAT-PMP против подставного шлюза', () {
    late _FakeGateway gateway;

    setUp(() async {
      gateway = await _FakeGateway.start();
    });

    tearDown(() async => gateway.stop());

    test('корректный ответ принимается, внешний порт отдаётся как есть',
        () async {
      gateway.onRequest = (data) => _natPmpMapResponse(
          protocol: PortProtocol.tcp,
          internalPort: 51413,
          externalPort: 51414,
          lifetime: 3600);

      final backend = _natPmpBackend(gateway);
      final result = await backend.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));

      expect(result, isNotNull, reason: 'подставной шлюз ответил корректно');
      expect(result!.externalPort, equals(51414));
      expect(result.internalPort, equals(51413));
    });

    test('ответ ПО ЧУЖОМУ ПРОТОКОЛУ не принимается', () async {
      // Шлюз отвечает UDP-опкодом на запрос TCP-маппинга. Байты валидны, поля
      // осмысленны — отличается только протокол. Приняв такой ответ, клиент
      // сообщил бы наружу внешний порт, которого для TCP не существует.
      var asked = 0;
      gateway.onRequest = (data) {
        asked++;
        return _natPmpMapResponse(
            protocol: PortProtocol.udp,
            internalPort: 51413,
            externalPort: 51414,
            lifetime: 3600);
      };

      final backend = _natPmpBackend(gateway);
      final result = await backend.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));

      expect(asked, greaterThan(0),
          reason: 'предусловие: запрос до подставного шлюза дошёл');
      expect(result, isNull,
          reason: 'ответ на UDP-маппинг не может закрывать запрос TCP');
    });

    test('отказ шлюза (result != 0) не превращается в маппинг', () async {
      gateway.onRequest = (data) => _natPmpMapResponse(
          protocol: PortProtocol.tcp,
          internalPort: 51413,
          externalPort: 0,
          lifetime: 0,
          resultCode: NatPmpResult.notAuthorized);

      final backend = _natPmpBackend(gateway);
      final result = await backend.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));

      expect(result, isNull);
      expect(backend.lastError, contains('not authorized'));
    });

    test('ответ с ЧУЖОГО адреса игнорируется', () async {
      // Отвечающий сокет слушает 0.0.0.0, поэтому получает запрос, куда бы в
      // пределах 127.0.0.0/8 его ни адресовали, — а вот ОТВЕЧАЕТ он всегда с
      // 127.0.0.1. Это и есть «ответил не тот, кого спрашивали», разыгранное
      // целиком на loopback.
      await gateway.stop();
      final wildcard =
          await _FakeGateway.start(address: InternetAddress.anyIPv4);
      addTearDown(wildcard.stop);
      var asked = 0;
      wildcard.onRequest = (data) {
        asked++;
        return _natPmpMapResponse(
            protocol: PortProtocol.tcp,
            internalPort: 51413,
            externalPort: 6666,
            lifetime: 3600);
      };

      // ПРЕДУСЛОВИЕ: спрашиваем ровно тот адрес, с которого придёт ответ, —
      // маппинг обязан получиться. Без этой половины «ответ проигнорирован»
      // подтверждалось бы на молчащем сокете, то есть ни на чём.
      final matching = NatPmpBackend(
        gateways: [InternetAddress.loopbackIPv4],
        transport: _fastTransport(wildcard.port),
      );
      final legit = await matching.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));
      expect(asked, greaterThan(0),
          reason: 'предусловие: подставной шлюз получает запросы и отвечает');
      expect(legit?.externalPort, equals(6666),
          reason: 'предусловие: этот же ответ принимается, когда источник '
              'совпадает со спрошенным адресом');

      // А теперь спрашиваем 127.0.0.3 — тот же сокет его получит и ответит,
      // но уже с 127.0.0.1.
      final askedAgain = asked;
      final wrongSource = NatPmpBackend(
        gateways: [InternetAddress('127.0.0.3')],
        transport: _fastTransport(wildcard.port),
      );
      final result = await wrongSource.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));

      expect(asked, greaterThan(askedAgain),
          reason: 'предусловие: запрос на 127.0.0.3 тоже дошёл и был отвечен');
      expect(result, isNull,
          reason: 'ответ пришёл не от того, кого спрашивали — принимать его '
              'значит позволить любому соседу назначать нам внешний адрес');
    });
  });

  group('PCP против подставного шлюза', () {
    late _FakeGateway gateway;

    setUp(() async {
      gateway = await _FakeGateway.start();
    });

    tearDown(() async => gateway.stop());

    test('корректный ответ с НАШИМ nonce принимается', () async {
      gateway.onRequest = (data) => _pcpMapResponseEchoingNonce(data,
          externalPort: 51414, lifetime: 3600);

      final backend = PcpBackend(
        gateways: [InternetAddress.loopbackIPv4],
        transport: _fastTransport(gateway.port),
      );
      final result = await backend.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));

      expect(result, isNotNull);
      expect(result!.externalPort, equals(51414));
    });

    test('ответ с ЧУЖИМ nonce не принимается', () async {
      var asked = 0;
      gateway.onRequest = (data) {
        asked++;
        // Всё то же самое, но nonce перевёрнут — то есть это ответ на чей-то
        // другой запрос, случайно долетевший до нашего сокета.
        final foreign = Uint8List.fromList(
            data.sublist(24, 24 + pcpNonceLength).reversed.toList());
        return _pcpMapResponse(
            nonce: foreign, externalPort: 51414, lifetime: 3600);
      };

      final backend = PcpBackend(
        gateways: [InternetAddress.loopbackIPv4],
        transport: _fastTransport(gateway.port),
      );
      final result = await backend.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));

      expect(asked, greaterThan(0),
          reason: 'предусловие: запрос до подставного шлюза дошёл');
      expect(result, isNull,
          reason: 'nonce — единственное, чем PCP отличает ответ на наш запрос '
              'от ответа на чужой');
    });

    test('снятие маппинга шлёт ТОТ ЖЕ nonce, что и установка', () async {
      Uint8List? mapNonce;
      Uint8List? unmapNonce;
      var lifetimeOnUnmap = -1;
      gateway.onRequest = (data) {
        final nonce =
            Uint8List.fromList(data.sublist(24, 24 + pcpNonceLength));
        final lifetime = ByteData.sublistView(data).getUint32(4);
        if (lifetime == 0) {
          unmapNonce = nonce;
          lifetimeOnUnmap = lifetime;
        } else {
          mapNonce = nonce;
        }
        return _pcpMapResponseEchoingNonce(data,
            externalPort: 51414, lifetime: lifetime);
      };

      final backend = PcpBackend(
        gateways: [InternetAddress.loopbackIPv4],
        transport: _fastTransport(gateway.port),
      );
      final mapping = await backend.map(
          internalPort: 51413,
          protocol: PortProtocol.tcp,
          lease: const Duration(seconds: 3600));
      expect(mapping, isNotNull, reason: 'предусловие: маппинг установлен');
      expect(mapNonce, isNotNull, reason: 'предусловие: nonce установки виден');

      final ok = await backend.unmap(mapping!);

      expect(ok, isTrue);
      expect(lifetimeOnUnmap, equals(0),
          reason: 'снятие — это MAP с нулевым сроком (RFC 6887 §15)');
      expect(unmapNonce, equals(mapNonce),
          reason: 'шлюз опознаёт запись по nonce: с новым nonce он снял бы '
              'не то или не снял ничего');
    });
  });
}

NatPmpBackend _natPmpBackend(_FakeGateway gateway) => NatPmpBackend(
      gateways: [InternetAddress.loopbackIPv4],
      transport: _fastTransport(gateway.port),
    );

/// Тот же транспорт, но с короткими паузами: проверяем правило, а не 2.5 с
/// ожидания на каждый негативный случай.
NatUdpTransaction _fastTransport(int port) => NatUdpTransaction(
      serverPort: port,
      retryDelays: const [Duration(milliseconds: 20)],
    );

/// Подставной шлюз: UDP-сокет, отвечающий тем, что вернёт [onRequest].
class _FakeGateway {
  final RawDatagramSocket _socket;
  Uint8List? Function(Uint8List request)? onRequest;

  _FakeGateway._(this._socket) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket.receive();
      if (dg == null) return;
      final reply = onRequest?.call(Uint8List.fromList(dg.data));
      if (reply == null) return;
      _socket.send(reply, dg.address, dg.port);
    });
  }

  int get port => _socket.port;

  static Future<_FakeGateway> start(
      {InternetAddress? address, int port = 0}) async {
    final s = await RawDatagramSocket.bind(
        address ?? InternetAddress.loopbackIPv4, port);
    return _FakeGateway._(s);
  }

  Future<void> stop() async => _socket.close();
}

Uint8List _natPmpMapResponse({
  required PortProtocol protocol,
  required int internalPort,
  required int externalPort,
  required int lifetime,
  int resultCode = NatPmpResult.success,
}) {
  final b = ByteData(16);
  b.setUint8(0, natPmpVersion);
  b.setUint8(1, natPmpOpcodeFor(protocol) + natPmpResponseFlag);
  b.setUint16(2, resultCode);
  b.setUint32(4, 1293467);
  b.setUint16(8, internalPort);
  b.setUint16(10, externalPort);
  b.setUint32(12, lifetime);
  return b.buffer.asUint8List();
}

Uint8List _pcpMapResponseEchoingNonce(Uint8List request,
        {required int externalPort, required int lifetime}) =>
    _pcpMapResponse(
        nonce: Uint8List.fromList(request.sublist(24, 24 + pcpNonceLength)),
        externalPort: externalPort,
        lifetime: lifetime);

Uint8List _pcpMapResponse({
  required Uint8List nonce,
  required int externalPort,
  required int lifetime,
  int resultCode = PcpResult.success,
}) {
  final out = Uint8List(pcpMapPacketLength);
  final b = ByteData.sublistView(out);
  b.setUint8(0, pcpVersion);
  b.setUint8(1, pcpOpcodeMap | pcpResponseFlag);
  b.setUint8(2, 0);
  b.setUint8(3, resultCode);
  b.setUint32(4, lifetime);
  b.setUint32(8, 1293467);
  out.setRange(24, 24 + pcpNonceLength, nonce);
  b.setUint8(36, PortProtocol.tcp.ianaNumber);
  b.setUint16(40, 51413);
  b.setUint16(42, externalPort);
  out.setRange(44, 60, pcpEncodeAddress(InternetAddress('109.195.195.251')));
  return out;
}
