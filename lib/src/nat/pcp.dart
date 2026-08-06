import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'gateway.dart';
import 'nat_backend.dart';
import 'nat_udp.dart';

/// PCP — Port Control Protocol (RFC 6887), наследник NAT-PMP.
///
/// Живёт на том же UDP 5351. Ставим его после NAT-PMP: там, где есть оба,
/// разницы для нас нет, а PCP заметно многословнее (60 байт против 12) и
/// строже к адресу клиента.

const int pcpVersion = 2;

const int pcpOpcodeMap = 1;

/// В ответах старший бит байта опкода поднят (R = 1).
const int pcpResponseFlag = 0x80;

const int pcpHeaderLength = 24;
const int pcpMapPayloadLength = 36;
const int pcpMapPacketLength = pcpHeaderLength + pcpMapPayloadLength;

const int pcpNonceLength = 12;

/// Коды результата (RFC 6887 §7.4).
class PcpResult {
  static const int success = 0;
  static const int unsuppVersion = 1;
  static const int notAuthorized = 2;
  static const int malformedRequest = 3;
  static const int unsuppOpcode = 4;
  static const int unsuppOption = 5;
  static const int malformedOption = 6;
  static const int networkFailure = 7;
  static const int noResources = 8;
  static const int unsuppProtocol = 9;
  static const int userExQuota = 10;
  static const int cannotProvideExternal = 11;
  static const int addressMismatch = 12;
  static const int excessiveRemotePeers = 13;

  static const Map<int, String> _names = {
    success: 'success',
    unsuppVersion: 'unsupported version',
    notAuthorized: 'not authorized (PCP выключен на шлюзе)',
    malformedRequest: 'malformed request',
    unsuppOpcode: 'unsupported opcode',
    unsuppOption: 'unsupported option',
    malformedOption: 'malformed option',
    networkFailure: 'network failure',
    noResources: 'no resources',
    unsuppProtocol: 'unsupported protocol',
    userExQuota: 'user exceeded quota',
    cannotProvideExternal: 'cannot provide external address',
    addressMismatch: 'address mismatch (наш IP не тот, что видит шлюз)',
    excessiveRemotePeers: 'excessive remote peers',
  };

  static String describe(int code) => _names[code] ?? 'unknown result code $code';
}

/// Адрес в виде 16 байт: PCP всегда оперирует IPv6, IPv4 кладётся как
/// IPv4-mapped (`::ffff:a.b.c.d`).
Uint8List pcpEncodeAddress(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.length == 16) return Uint8List.fromList(raw);
  final out = Uint8List(16);
  out[10] = 0xff;
  out[11] = 0xff;
  out.setRange(12, 16, raw);
  return out;
}

/// Обратное преобразование: IPv4-mapped разворачивается в честный IPv4.
InternetAddress pcpDecodeAddress(List<int> bytes) {
  if (bytes.length != 16) {
    return InternetAddress.fromRawAddress(Uint8List.fromList(bytes));
  }
  final isV4Mapped = bytes.take(10).every((b) => b == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (isV4Mapped) {
    return InternetAddress.fromRawAddress(
        Uint8List.fromList(bytes.sublist(12, 16)));
  }
  return InternetAddress.fromRawAddress(Uint8List.fromList(bytes));
}

Uint8List generatePcpNonce([Random? random]) {
  final r = random ?? Random.secure();
  return Uint8List.fromList(
      List<int>.generate(pcpNonceLength, (_) => r.nextInt(256)));
}

/// Сборка запроса MAP (RFC 6887 §11.1).
///
/// Снятие маппинга — тот же запрос с `lifetimeSeconds = 0` и ТЕМ ЖЕ [nonce]:
/// шлюз опознаёт запись именно по нему.
Uint8List buildPcpMapRequest({
  required Uint8List nonce,
  required PortProtocol protocol,
  required int internalPort,
  required int suggestedExternalPort,
  required InternetAddress clientAddress,
  required int lifetimeSeconds,
  InternetAddress? suggestedExternalAddress,
}) {
  if (nonce.length != pcpNonceLength) {
    throw ArgumentError('PCP nonce должен быть $pcpNonceLength байт');
  }
  final out = Uint8List(pcpMapPacketLength);
  final b = ByteData.sublistView(out);
  b.setUint8(0, pcpVersion);
  b.setUint8(1, pcpOpcodeMap); // R = 0 (запрос)
  b.setUint16(2, 0); // reserved
  b.setUint32(4, lifetimeSeconds);
  out.setRange(8, 24, pcpEncodeAddress(clientAddress));

  out.setRange(24, 24 + pcpNonceLength, nonce);
  b.setUint8(36, protocol.ianaNumber);
  b.setUint8(37, 0);
  b.setUint8(38, 0);
  b.setUint8(39, 0); // reserved (24 бита)
  b.setUint16(40, internalPort);
  b.setUint16(42, suggestedExternalPort);
  out.setRange(
      44,
      60,
      pcpEncodeAddress(
          suggestedExternalAddress ?? InternetAddress.anyIPv4));
  return out;
}

/// Ответ на MAP.
class PcpMapResponse {
  final int resultCode;
  final int lifetimeSeconds;
  final int epochSeconds;
  final Uint8List nonce;
  final PortProtocol? protocol;
  final int internalPort;
  final int externalPort;
  final InternetAddress externalAddress;

  PcpMapResponse({
    required this.resultCode,
    required this.lifetimeSeconds,
    required this.epochSeconds,
    required this.nonce,
    required this.protocol,
    required this.internalPort,
    required this.externalPort,
    required this.externalAddress,
  });

  bool get isSuccess => resultCode == PcpResult.success;
}

/// Разбор ответа MAP. `null` — пакет не наш/битый.
/// Покрыто: test/pcp_test.dart.
PcpMapResponse? parsePcpMapResponse(Uint8List data) {
  if (data.length < pcpMapPacketLength) return null;
  final b = ByteData.sublistView(data);
  if (b.getUint8(0) != pcpVersion) return null;
  if (b.getUint8(1) != (pcpOpcodeMap | pcpResponseFlag)) return null;
  final protocolByte = b.getUint8(36);
  return PcpMapResponse(
    resultCode: b.getUint8(3),
    lifetimeSeconds: b.getUint32(4),
    epochSeconds: b.getUint32(8),
    nonce: Uint8List.fromList(data.sublist(24, 24 + pcpNonceLength)),
    protocol: protocolByte == PortProtocol.tcp.ianaNumber
        ? PortProtocol.tcp
        : (protocolByte == PortProtocol.udp.ianaNumber
            ? PortProtocol.udp
            : null),
    internalPort: b.getUint16(40),
    externalPort: b.getUint16(42),
    externalAddress: pcpDecodeAddress(data.sublist(44, 60)),
  );
}

/// Бэкенд PCP.
class PcpBackend implements NatBackend {
  List<InternetAddress>? _gateways;
  InternetAddress? _activeGateway;
  InternetAddress? _externalAddress;

  final NatUdpTransaction _transport;
  final Iterable<InternetAddress> _extraCandidates;
  final Random? _random;

  /// nonce живёт столько же, сколько маппинг: продление и снятие обязаны
  /// прийти с тем же значением, иначе шлюз посчитает это чужим запросом.
  final Map<String, Uint8List> _nonces = {};

  String? _lastError;

  PcpBackend({
    List<InternetAddress>? gateways,
    Iterable<InternetAddress> extraCandidates = const [],
    NatUdpTransaction? transport,
    Random? random,
  })  : _gateways = gateways,
        _extraCandidates = extraCandidates,
        _transport = transport ?? NatUdpTransaction(),
        _random = random;

  @override
  PortMapMethod get method => PortMapMethod.pcp;

  @override
  String? get lastError => _lastError;

  InternetAddress? get activeGateway => _activeGateway;

  String _key(PortProtocol p, int internalPort) => '${p.name}:$internalPort';

  Future<List<InternetAddress>> _candidates() async {
    final active = _activeGateway;
    if (active != null) return [active];
    return _gateways ??=
        await discoverGatewayCandidates(extraCandidates: _extraCandidates);
  }

  @override
  Future<InternetAddress?> externalAddress() async => _externalAddress;

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
    final key = _key(protocol, internalPort);
    final nonce = _nonces[key] ??= generatePcpNonce(_random);

    // Клиентский адрес обязателен и обязан совпасть с тем, который шлюз видит
    // как источник, — иначе ADDRESS_MISMATCH. Берём адрес интерфейса, самым
    // длинным префиксом совпадающий с адресом шлюза.
    final client = await localAddressFor(gateways.first);
    if (client == null) {
      _lastError = 'не удалось определить собственный LAN-адрес для PCP';
      return null;
    }
    final payload = buildPcpMapRequest(
      nonce: nonce,
      protocol: protocol,
      internalPort: internalPort,
      suggestedExternalPort: suggestedExternalPort ?? internalPort,
      clientAddress: client,
      lifetimeSeconds: lease.inSeconds,
    );
    final reply = await _transport.request(
      gateways: gateways,
      payload: payload,
      accept: (_, data) {
        final r = parsePcpMapResponse(data);
        // Сверка nonce — единственное, что отличает ответ на НАШ запрос от
        // ответа на чужой: по одному сокету ходят и TCP-, и UDP-маппинги.
        return r != null && _sameNonce(r.nonce, nonce);
      },
    );
    if (reply == null) {
      _lastError = 'шлюз не ответил на PCP MAP';
      return null;
    }
    _activeGateway = reply.gateway;
    final parsed = parsePcpMapResponse(reply.data)!;
    if (!parsed.isSuccess) {
      _lastError = 'PCP: ${PcpResult.describe(parsed.resultCode)}';
      return null;
    }
    _lastError = null;
    _externalAddress = parsed.externalAddress;
    return MappedPort(
      method: PortMapMethod.pcp,
      protocol: protocol,
      internalPort: parsed.internalPort,
      externalPort: parsed.externalPort,
      externalAddress: parsed.externalAddress,
      lifetime: Duration(seconds: parsed.lifetimeSeconds),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<bool> unmap(MappedPort mapping) async {
    final gateways = await _candidates();
    if (gateways.isEmpty) return false;
    final key = _key(mapping.protocol, mapping.internalPort);
    final nonce = _nonces[key];
    // Без сохранённого nonce снять маппинг нечем — шлюз его не опознает.
    if (nonce == null) return false;
    final client = await localAddressFor(gateways.first);
    if (client == null) return false;
    final payload = buildPcpMapRequest(
      nonce: nonce,
      protocol: mapping.protocol,
      internalPort: mapping.internalPort,
      suggestedExternalPort: 0,
      clientAddress: client,
      lifetimeSeconds: 0,
    );
    final reply = await _transport.request(
      gateways: gateways,
      payload: payload,
      accept: (_, data) {
        final r = parsePcpMapResponse(data);
        return r != null && _sameNonce(r.nonce, nonce);
      },
    );
    _nonces.remove(key);
    if (reply == null) return false;
    return parsePcpMapResponse(reply.data)!.isSuccess;
  }

  @override
  Future<void> dispose() async {
    _activeGateway = null;
    _externalAddress = null;
    _gateways = null;
    _nonces.clear();
  }

  static bool _sameNonce(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
