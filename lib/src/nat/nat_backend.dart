import 'dart:io';

/// Каким способом получен внешний порт.
///
/// Порядок значений — это и порядок предпочтения при выборе бэкенда:
/// UPnP IGD распространён шире всего, NAT-PMP/PCP компактнее и быстрее, но
/// живут в основном на прошивках на базе miniupnpd/Apple.
enum PortMapMethod {
  /// UPnP Internet Gateway Device (SSDP discovery + SOAP AddPortMapping).
  upnpIgd,

  /// NAT-PMP, RFC 6886.
  natPmp,

  /// Port Control Protocol, RFC 6887.
  pcp,

  /// Маппинга не делали (или не удалось), но входящие снаружи всё равно
  /// приходят — значит порт проброшен руками либо NAT'а перед нами нет.
  manual,

  /// Внешний порт не получен.
  none,
}

/// Транспорт, для которого просим маппинг.
///
/// BitTorrent'у нужны оба: TCP — классические пиры, UDP — uTP и DHT.
enum PortProtocol { tcp, udp }

extension PortProtocolName on PortProtocol {
  /// Имя протокола так, как его ждёт UPnP IGD (`NewProtocol`).
  String get upnpName => this == PortProtocol.tcp ? 'TCP' : 'UDP';

  /// Номер протокола IANA — им пользуется PCP (RFC 6887, поле Protocol).
  int get ianaNumber => this == PortProtocol.tcp ? 6 : 17;
}

/// Успешно установленный маппинг одного порта одного протокола.
///
/// Значимый объект без поведения: состояние, нужное для продления и снятия
/// (nonce у PCP, control URL у UPnP), бэкенд держит у себя, чтобы этот класс
/// оставался сравнимым по значению и удобным в тестах.
class MappedPort {
  final PortMapMethod method;
  final PortProtocol protocol;

  /// Порт, на котором слушаем мы сами.
  final int internalPort;

  /// Порт, который выделил шлюз. **Не обязан совпадать** с [internalPort] —
  /// на домашнем стенде запрос 51413 вернул 51414, потому что 51413 на шлюзе
  /// был занят. Именно [externalPort] уходит в анонс и в диагностику.
  final int externalPort;

  /// Внешний (WAN) адрес шлюза, если бэкенд смог его узнать.
  final InternetAddress? externalAddress;

  /// Срок аренды, выданный шлюзом (не тот, что просили: шлюз вправе укоротить).
  final Duration lifetime;

  final DateTime createdAt;

  MappedPort({
    required this.method,
    required this.protocol,
    required this.internalPort,
    required this.externalPort,
    required this.lifetime,
    required this.createdAt,
    this.externalAddress,
  });

  DateTime get expiresAt => createdAt.add(lifetime);

  /// Бессрочный маппинг: часть IGD не умеет аренду и отдаёт `0`.
  bool get isPermanent => lifetime == Duration.zero;

  @override
  bool operator ==(Object other) =>
      other is MappedPort &&
      other.method == method &&
      other.protocol == protocol &&
      other.internalPort == internalPort &&
      other.externalPort == externalPort &&
      other.externalAddress?.address == externalAddress?.address &&
      other.lifetime == lifetime &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(method, protocol, internalPort, externalPort,
      externalAddress?.address, lifetime, createdAt);

  @override
  String toString() => 'MappedPort(${method.name}, ${protocol.name}, '
      '$internalPort -> ${externalAddress?.address ?? '?'}:$externalPort, '
      'lease ${lifetime.inSeconds}s)';
}

/// Один способ пробить порт на шлюзе.
///
/// Контракт для всех реализаций:
/// * [map] возвращает `null`, если способ здесь не работает (шлюз молчит,
///   отвечает отказом, не найден) — вызывающая сторона просто берёт следующий
///   бэкенд. Исключения наружу не выпускаются, причина кладётся в [lastError].
/// * [map] идемпотентен: повторный вызов с теми же аргументами продлевает
///   аренду, а не плодит записи.
/// * [unmap] снимает ровно то, что выдал [map]; ошибки глотает — на выходе
///   из приложения падать из-за шлюза нельзя.
abstract class NatBackend {
  PortMapMethod get method;

  /// Человекочитаемая причина последней неудачи, либо `null`.
  String? get lastError;

  /// Установить или продлить маппинг [internalPort] для [protocol].
  ///
  /// [lease] — желаемый срок аренды; `Duration.zero` означает «бессрочно»
  /// (не все шлюзы это принимают). [suggestedExternalPort] по умолчанию равен
  /// [internalPort] — шлюз вправе выдать другой.
  Future<MappedPort?> map({
    required int internalPort,
    required PortProtocol protocol,
    required Duration lease,
    int? suggestedExternalPort,
  });

  /// Снять маппинг. Возвращает `true`, если шлюз подтвердил снятие.
  Future<bool> unmap(MappedPort mapping);

  /// Внешний (WAN) адрес шлюза, если известен.
  Future<InternetAddress?> externalAddress();

  Future<void> dispose();
}
