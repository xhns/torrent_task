import 'dart:io';

import 'nat_backend.dart';

/// Достижима ли наша раздача извне — и если нет, то почему.
///
/// Без этой сводки пользователь остаётся в положении «0 роздано, и непонятно
/// почему»: раздача при закрытом порте выглядит ровно как раздача, которую
/// никто не качает.
class Reachability {
  /// Порт, который у движка попросили.
  final int configuredPort;

  /// Порт, на котором мы РЕАЛЬНО слушаем TCP. Может отличаться от
  /// [configuredPort], если тот был занят и пришлось взять эфемерный.
  final int listenPort;

  /// Порт, на котором слушаем UDP (входящий uTP). `0` — uTP не слушаем.
  final int utpPort;

  /// Способ, которым получен внешний порт.
  final PortMapMethod mappingMethod;

  /// Внешний (WAN) адрес, если удалось узнать.
  final InternetAddress? externalAddress;

  /// Внешний TCP-порт. **Не обязан** совпадать с [listenPort].
  final int? externalTcpPort;

  /// Внешний UDP-порт.
  final int? externalUdpPort;

  /// Когда истекает аренда маппинга (`null` — бессрочный или маппинга нет).
  final DateTime? mappingExpiresAt;

  /// Почему маппинга нет или он неполный.
  final String? mappingError;

  /// Сколько входящих TCP-соединений принято за сессию.
  final int incomingTcpConnections;

  /// Сколько входящих uTP-соединений принято за сессию.
  final int incomingUtpConnections;

  /// Сколько входящих пришло с публичных адресов.
  ///
  /// Это единственное прямое доказательство достижимости: маппинг мог
  /// «удаться» на промежуточном роутере, за которым всё равно CGNAT.
  final int incomingFromWanConnections;

  const Reachability({
    required this.configuredPort,
    required this.listenPort,
    this.utpPort = 0,
    this.mappingMethod = PortMapMethod.none,
    this.externalAddress,
    this.externalTcpPort,
    this.externalUdpPort,
    this.mappingExpiresAt,
    this.mappingError,
    this.incomingTcpConnections = 0,
    this.incomingUtpConnections = 0,
    this.incomingFromWanConnections = 0,
  });

  /// Слушаем ли тот порт, который просили.
  ///
  /// `false` означает, что ручной проброс на роутере, настроенный
  /// пользователем на [configuredPort], сейчас ведёт в никуда.
  bool get listeningOnConfiguredPort => listenPort == configuredPort;

  int get incomingConnections =>
      incomingTcpConnections + incomingUtpConnections;

  /// Есть ли доказательство, что снаружи до нас достучались.
  bool get provenReachable => incomingFromWanConnections > 0;

  /// Способ с поправкой на факты.
  ///
  /// Автоматического маппинга нет, а входящие из интернета есть — значит порт
  /// проброшен руками или NAT'а перед нами нет. Такой клиент достижим, и
  /// говорить ему «вы за NAT» было бы враньём.
  /// Покрыто: test/reachability_test.dart.
  PortMapMethod get effectiveMethod {
    if (mappingMethod == PortMapMethod.none && provenReachable) {
      return PortMapMethod.manual;
    }
    return mappingMethod;
  }

  /// Внешняя точка входа в человекочитаемом виде, либо `null`.
  String? get externalEndpoint {
    final a = externalAddress;
    final p = externalTcpPort;
    if (a == null || p == null) return null;
    return '${a.address}:$p';
  }

  Reachability copyWith({
    int? configuredPort,
    int? listenPort,
    int? utpPort,
    PortMapMethod? mappingMethod,
    InternetAddress? externalAddress,
    int? externalTcpPort,
    int? externalUdpPort,
    DateTime? mappingExpiresAt,
    String? mappingError,
    int? incomingTcpConnections,
    int? incomingUtpConnections,
    int? incomingFromWanConnections,
  }) {
    return Reachability(
      configuredPort: configuredPort ?? this.configuredPort,
      listenPort: listenPort ?? this.listenPort,
      utpPort: utpPort ?? this.utpPort,
      mappingMethod: mappingMethod ?? this.mappingMethod,
      externalAddress: externalAddress ?? this.externalAddress,
      externalTcpPort: externalTcpPort ?? this.externalTcpPort,
      externalUdpPort: externalUdpPort ?? this.externalUdpPort,
      mappingExpiresAt: mappingExpiresAt ?? this.mappingExpiresAt,
      mappingError: mappingError ?? this.mappingError,
      incomingTcpConnections:
          incomingTcpConnections ?? this.incomingTcpConnections,
      incomingUtpConnections:
          incomingUtpConnections ?? this.incomingUtpConnections,
      incomingFromWanConnections:
          incomingFromWanConnections ?? this.incomingFromWanConnections,
    );
  }

  Map<String, dynamic> toJson() => {
        'configuredPort': configuredPort,
        'listenPort': listenPort,
        'utpPort': utpPort,
        'listeningOnConfiguredPort': listeningOnConfiguredPort,
        'method': effectiveMethod.name,
        'externalAddress': externalAddress?.address,
        'externalTcpPort': externalTcpPort,
        'externalUdpPort': externalUdpPort,
        'mappingExpiresAt': mappingExpiresAt?.toIso8601String(),
        'mappingError': mappingError,
        'incomingTcpConnections': incomingTcpConnections,
        'incomingUtpConnections': incomingUtpConnections,
        'incomingFromWanConnections': incomingFromWanConnections,
        'provenReachable': provenReachable,
      };

  @override
  String toString() => 'Reachability(listen=$listenPort/utp=$utpPort, '
      '${effectiveMethod.name}, external=${externalEndpoint ?? '-'}, '
      'incoming=$incomingConnections (wan $incomingFromWanConnections))';
}

/// Приватный ли адрес по RFC 1918/4193 и родне.
///
/// Нужен, чтобы отличить «до нас достучались из интернета» от «до нас
/// достучался сосед по Wi-Fi через LSD»: второе о проходимости NAT ничего не
/// говорит.
/// Покрыто: test/reachability_test.dart.
bool isPrivateAddress(InternetAddress address) {
  if (address.isLoopback) return true;
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    if (raw.length != 4) return true;
    if (raw[0] == 10) return true;
    if (raw[0] == 127) return true;
    if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
    if (raw[0] == 192 && raw[1] == 168) return true;
    if (raw[0] == 169 && raw[1] == 254) return true; // link-local
    // 100.64.0.0/10 — CGNAT (RFC 6598). Соединение оттуда пришло изнутри сети
    // провайдера, а не из «настоящего» интернета.
    if (raw[0] == 100 && raw[1] >= 64 && raw[1] <= 127) return true;
    if (raw[0] == 0) return true;
    return false;
  }
  if (raw.isEmpty) return true;
  if ((raw[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique-local
  if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true; // fe80::/10
  return false;
}
