import 'dart:io';
import 'dart:typed_data';

import 'gateway.dart';
import 'nat_backend.dart';
import 'nat_udp.dart';

/// NAT-PMP (RFC 6886).
///
/// Протокол бинарный и крошечный (запрос 2 или 12 байт), готового пакета в
/// pub.dev нет — реализован здесь целиком.

const int natPmpVersion = 0;

const int natPmpOpExternalAddress = 0;
const int natPmpOpMapUdp = 1;
const int natPmpOpMapTcp = 2;

/// Ответы приходят с тем же опкодом плюс 128 (RFC 6886 §3).
const int natPmpResponseFlag = 128;

/// Коды результата (RFC 6886 §3.5).
class NatPmpResult {
  static const int success = 0;
  static const int unsupportedVersion = 1;
  static const int notAuthorized = 2;
  static const int networkFailure = 3;
  static const int outOfResources = 4;
  static const int unsupportedOpcode = 5;

  static String describe(int code) {
    switch (code) {
      case success:
        return 'success';
      case unsupportedVersion:
        return 'unsupported version';
      case notAuthorized:
        return 'not authorized / refused (NAT-PMP выключен на шлюзе)';
      case networkFailure:
        return 'network failure (шлюз сам не получил внешний адрес)';
      case outOfResources:
        return 'out of resources (у шлюза кончились маппинги)';
      case unsupportedOpcode:
        return 'unsupported opcode';
      default:
        return 'unknown result code $code';
    }
  }
}

int natPmpOpcodeFor(PortProtocol protocol) =>
    protocol == PortProtocol.tcp ? natPmpOpMapTcp : natPmpOpMapUdp;

/// Запрос внешнего адреса: версия + опкод, всего два байта.
Uint8List buildNatPmpExternalAddressRequest() =>
    Uint8List.fromList([natPmpVersion, natPmpOpExternalAddress]);

/// Запрос маппинга (RFC 6886 §3.3).
///
/// Снятие маппинга — тот же запрос с `externalPort = 0` и `lifetime = 0`.
Uint8List buildNatPmpMapRequest({
  required PortProtocol protocol,
  required int internalPort,
  required int externalPort,
  required int lifetimeSeconds,
}) {
  final b = ByteData(12);
  b.setUint8(0, natPmpVersion);
  b.setUint8(1, natPmpOpcodeFor(protocol));
  b.setUint16(2, 0); // reserved
  b.setUint16(4, internalPort);
  b.setUint16(6, externalPort);
  b.setUint32(8, lifetimeSeconds);
  return b.buffer.asUint8List();
}

/// Ответ на запрос внешнего адреса.
class NatPmpExternalAddressResponse {
  final int resultCode;
  final int epochSeconds;
  final InternetAddress? externalAddress;

  NatPmpExternalAddressResponse(
      this.resultCode, this.epochSeconds, this.externalAddress);

  bool get isSuccess => resultCode == NatPmpResult.success;
}

/// Ответ на запрос маппинга.
class NatPmpMapResponse {
  final int resultCode;
  final int epochSeconds;
  final int internalPort;
  final int externalPort;
  final int lifetimeSeconds;
  final PortProtocol protocol;

  NatPmpMapResponse({
    required this.resultCode,
    required this.epochSeconds,
    required this.internalPort,
    required this.externalPort,
    required this.lifetimeSeconds,
    required this.protocol,
  });

  bool get isSuccess => resultCode == NatPmpResult.success;
}

/// Разбор ответа на запрос внешнего адреса. `null` — пакет не наш/битый.
/// Покрыто: test/nat_pmp_test.dart.
NatPmpExternalAddressResponse? parseNatPmpExternalAddressResponse(
    Uint8List data) {
  if (data.length < 12) return null;
  final b = ByteData.sublistView(data);
  if (b.getUint8(0) != natPmpVersion) return null;
  if (b.getUint8(1) != natPmpOpExternalAddress + natPmpResponseFlag) {
    return null;
  }
  final result = b.getUint16(2);
  final epoch = b.getUint32(4);
  // При ненулевом коде результата поле адреса не определено — не выдумываем.
  final addr = result == NatPmpResult.success
      ? InternetAddress.fromRawAddress(
          Uint8List.fromList(data.sublist(8, 12)))
      : null;
  return NatPmpExternalAddressResponse(result, epoch, addr);
}

/// Разбор ответа на запрос маппинга. `null` — пакет не наш/битый.
/// Покрыто: test/nat_pmp_test.dart.
NatPmpMapResponse? parseNatPmpMapResponse(Uint8List data) {
  if (data.length < 16) return null;
  final b = ByteData.sublistView(data);
  if (b.getUint8(0) != natPmpVersion) return null;
  final op = b.getUint8(1);
  if (op != natPmpOpMapUdp + natPmpResponseFlag &&
      op != natPmpOpMapTcp + natPmpResponseFlag) {
    return null;
  }
  return NatPmpMapResponse(
    resultCode: b.getUint16(2),
    epochSeconds: b.getUint32(4),
    internalPort: b.getUint16(8),
    externalPort: b.getUint16(10),
    lifetimeSeconds: b.getUint32(12),
    protocol: op == natPmpOpMapTcp + natPmpResponseFlag
        ? PortProtocol.tcp
        : PortProtocol.udp,
  );
}

/// Бэкенд NAT-PMP.
class NatPmpBackend implements NatBackend {
  /// Кандидаты в шлюзы. `null` — определить самостоятельно при первом запросе.
  List<InternetAddress>? _gateways;

  /// Шлюз, который ответил: дальше говорим только с ним.
  InternetAddress? _activeGateway;

  InternetAddress? _externalAddress;

  final NatUdpTransaction _transport;

  final Iterable<InternetAddress> _extraCandidates;

  String? _lastError;

  NatPmpBackend({
    List<InternetAddress>? gateways,
    Iterable<InternetAddress> extraCandidates = const [],
    NatUdpTransaction? transport,
  })  : _gateways = gateways,
        _extraCandidates = extraCandidates,
        _transport = transport ?? NatUdpTransaction();

  @override
  PortMapMethod get method => PortMapMethod.natPmp;

  @override
  String? get lastError => _lastError;

  /// Шлюз, с которым в итоге договорились (для диагностики).
  InternetAddress? get activeGateway => _activeGateway;

  Future<List<InternetAddress>> _candidates() async {
    final active = _activeGateway;
    if (active != null) return [active];
    return _gateways ??=
        await discoverGatewayCandidates(extraCandidates: _extraCandidates);
  }

  @override
  Future<InternetAddress?> externalAddress() async {
    final cached = _externalAddress;
    if (cached != null) return cached;
    final gateways = await _candidates();
    final reply = await _transport.request(
      gateways: gateways,
      payload: buildNatPmpExternalAddressRequest(),
      accept: (_, data) => parseNatPmpExternalAddressResponse(data) != null,
    );
    if (reply == null) {
      _lastError = 'шлюз не ответил на NAT-PMP (${gateways.length} кандидатов)';
      return null;
    }
    final parsed = parseNatPmpExternalAddressResponse(reply.data)!;
    _activeGateway = reply.gateway;
    if (!parsed.isSuccess) {
      _lastError = 'NAT-PMP: ${NatPmpResult.describe(parsed.resultCode)}';
      return null;
    }
    _lastError = null;
    return _externalAddress = parsed.externalAddress;
  }

  @override
  Future<MappedPort?> map({
    required int internalPort,
    required PortProtocol protocol,
    required Duration lease,
    int? suggestedExternalPort,
  }) async {
    final gateways = await _candidates();
    if (gateways.isEmpty) {
      _lastError = 'не найдено ни одного кандидата в шлюзы';
      return null;
    }
    final payload = buildNatPmpMapRequest(
      protocol: protocol,
      internalPort: internalPort,
      externalPort: suggestedExternalPort ?? internalPort,
      lifetimeSeconds: lease.inSeconds,
    );
    final reply = await _transport.request(
      gateways: gateways,
      payload: payload,
      accept: (_, data) {
        final r = parseNatPmpMapResponse(data);
        // Ответы на TCP- и UDP-маппинг ходят по одному сокету: без сверки
        // протокола запрос TCP мог бы «поймать» чужой UDP-ответ и отдать
        // наружу неверный внешний порт.
        return r != null && r.protocol == protocol;
      },
    );
    if (reply == null) {
      _lastError = 'шлюз не ответил на NAT-PMP AddMapping';
      return null;
    }
    _activeGateway = reply.gateway;
    final parsed = parseNatPmpMapResponse(reply.data)!;
    if (!parsed.isSuccess) {
      _lastError = 'NAT-PMP: ${NatPmpResult.describe(parsed.resultCode)}';
      return null;
    }
    _lastError = null;
    return MappedPort(
      method: PortMapMethod.natPmp,
      protocol: protocol,
      internalPort: parsed.internalPort,
      externalPort: parsed.externalPort,
      externalAddress: await externalAddress(),
      lifetime: Duration(seconds: parsed.lifetimeSeconds),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<bool> unmap(MappedPort mapping) async {
    final gateways = await _candidates();
    if (gateways.isEmpty) return false;
    // RFC 6886 §3.4: снятие — тот же запрос с нулевыми внешним портом и
    // сроком; внутренний порт обязан остаться прежним, иначе шлюз не поймёт,
    // что удалять.
    final payload = buildNatPmpMapRequest(
      protocol: mapping.protocol,
      internalPort: mapping.internalPort,
      externalPort: 0,
      lifetimeSeconds: 0,
    );
    final reply = await _transport.request(
      gateways: gateways,
      payload: payload,
      accept: (_, data) {
        final r = parseNatPmpMapResponse(data);
        return r != null && r.protocol == mapping.protocol;
      },
    );
    if (reply == null) return false;
    final parsed = parseNatPmpMapResponse(reply.data)!;
    return parsed.isSuccess;
  }

  @override
  Future<void> dispose() async {
    _activeGateway = null;
    _externalAddress = null;
    _gateways = null;
  }
}
