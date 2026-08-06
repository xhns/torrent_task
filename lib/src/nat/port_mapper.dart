import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'nat_backend.dart';
import 'nat_pmp.dart';
import 'pcp.dart';
import 'upnp_igd.dart';

export 'nat_backend.dart'
    show PortMapMethod, PortProtocol, MappedPort, NatBackend;

/// Сводное состояние проброса порта.
class PortMapperStatus {
  /// Способ, которым получен внешний порт, либо [PortMapMethod.none].
  final PortMapMethod method;

  /// Маппинг TCP — по нему к нам приходят обычные BitTorrent-пиры.
  final MappedPort? tcp;

  /// Маппинг UDP — по нему приходит uTP.
  final MappedPort? udp;

  /// Причина последней неудачи, если маппинга нет или он частичный.
  final String? error;

  final DateTime? lastAttemptAt;

  const PortMapperStatus({
    this.method = PortMapMethod.none,
    this.tcp,
    this.udp,
    this.error,
    this.lastAttemptAt,
  });

  bool get isMapped => tcp != null || udp != null;

  InternetAddress? get externalAddress =>
      tcp?.externalAddress ?? udp?.externalAddress;

  int? get externalTcpPort => tcp?.externalPort;

  int? get externalUdpPort => udp?.externalPort;

  DateTime? get expiresAt {
    final t = tcp;
    final u = udp;
    if (t != null && t.isPermanent) return null;
    if (t != null) return t.expiresAt;
    if (u != null && !u.isPermanent) return u.expiresAt;
    return null;
  }

  @override
  String toString() => 'PortMapperStatus(${method.name}, '
      'tcp=${tcp?.externalPort}, udp=${udp?.externalPort}'
      '${error == null ? '' : ', error=$error'})';
}

/// Единая точка проброса порта на шлюзе.
///
/// Внутри — несколько бэкендов, пробуемых по очереди: UPnP IGD (самый
/// распространённый), NAT-PMP, PCP. Победивший бэкенд запоминается, аренда
/// продлевается таймером, при [unmap] маппинг снимается.
///
/// Наружу отдаются ВНЕШНИЕ адрес и порт — они, а не локальный порт, нужны и
/// анонсу, и диагностике: на домашнем стенде запрос внутреннего 51413 вернул
/// внешний 51414, и клиент, анонсирующий 51413, был бы недостижим.
class PortMapper {
  static const Duration defaultLease = Duration(seconds: 3600);

  /// Бэкенды в порядке предпочтения.
  final List<NatBackend> backends;

  /// Как рано до истечения аренды её продлевать: половина срока — компромисс
  /// между лишним трафиком и риском не успеть после перезагрузки шлюза.
  final double renewalFraction;

  final Duration minRenewInterval;
  final Duration maxRenewInterval;

  /// Паузы перед повторной попыткой после неудачи (потом повторяется последняя).
  final List<Duration> retrySchedule;

  final StreamController<PortMapperStatus> _statusController =
      StreamController<PortMapperStatus>.broadcast();

  PortMapperStatus _status = const PortMapperStatus();

  NatBackend? _active;

  Timer? _renewTimer;
  int _failureCount = 0;
  bool _disposed = false;

  int? _internalPort;
  Duration _lease = defaultLease;
  Set<PortProtocol> _protocols = const {PortProtocol.tcp, PortProtocol.udp};

  PortMapper({
    List<NatBackend>? backends,
    String description = 'torrent_task',
    this.renewalFraction = 0.5,
    this.minRenewInterval = const Duration(seconds: 60),
    this.maxRenewInterval = const Duration(minutes: 30),
    this.retrySchedule = const [
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
    ],
  }) : backends = backends ?? defaultBackends(description: description);

  /// Набор бэкендов по умолчанию.
  ///
  /// UPnP первый намеренно: он есть на подавляющем большинстве домашних
  /// роутеров, тогда как NAT-PMP/PCP встречаются в основном на прошивках с
  /// miniupnpd и у Apple. Порядок ещё и диагностически удобен — если сработал
  /// не первый, значит с UPnP на этом роутере что-то не так.
  static List<NatBackend> defaultBackends({String description = 'torrent_task'}) =>
      [
        UpnpIgdBackend(description: description),
        NatPmpBackend(),
        PcpBackend(),
      ];

  PortMapperStatus get status => _status;

  Stream<PortMapperStatus> get onStatus => _statusController.stream;

  /// Пробросить [internalPort] наружу.
  ///
  /// Возвращает TCP-маппинг (он же — то, что уходит в анонс), либо `null`,
  /// если ни один бэкенд не смог. Полная картина, включая UDP, — в [status].
  Future<MappedPort?> map({
    required int internalPort,
    Duration lease = defaultLease,
    Set<PortProtocol> protocols = const {PortProtocol.tcp, PortProtocol.udp},
  }) async {
    if (_disposed) return null;
    _internalPort = internalPort;
    _lease = lease;
    _protocols = protocols;
    return (await _attempt()).tcp;
  }

  Future<PortMapperStatus> _attempt() async {
    final internalPort = _internalPort;
    if (internalPort == null) return _status;

    // Сначала бэкенд, который уже работал: переоткрывать discovery на каждое
    // продление — лишние секунды и лишний мультикаст в сеть.
    final order = <NatBackend>[
      if (_active != null) _active!,
      for (var b in backends)
        if (!identical(b, _active)) b
    ];

    String? lastError;
    for (var backend in order) {
      MappedPort? tcp;
      MappedPort? udp;
      if (_protocols.contains(PortProtocol.tcp)) {
        tcp = await _safeMap(backend, internalPort, PortProtocol.tcp);
        if (tcp == null) {
          lastError = backend.lastError ?? 'бэкенд ${backend.method.name} не смог';
          continue;
        }
      }
      if (_protocols.contains(PortProtocol.udp)) {
        udp = await _safeMap(backend, internalPort, PortProtocol.udp);
      }
      if (tcp == null && udp == null) {
        lastError = backend.lastError ?? 'бэкенд ${backend.method.name} не смог';
        continue;
      }
      _active = backend;
      _failureCount = 0;
      // UDP мог не получиться при живом TCP — это не провал целиком, но и
      // молчать нельзя: без UDP входящий uTP до нас не дойдёт.
      final partial = _protocols.contains(PortProtocol.udp) && udp == null;
      _emit(PortMapperStatus(
        method: backend.method,
        tcp: tcp,
        udp: udp,
        error: partial
            ? 'UDP не проброшен: ${backend.lastError ?? 'причина неизвестна'}'
            : null,
        lastAttemptAt: DateTime.now(),
      ));
      _scheduleRenew(tcp ?? udp!);
      return _status;
    }

    _active = null;
    _failureCount++;
    _emit(PortMapperStatus(
      method: PortMapMethod.none,
      error: lastError ?? 'ни один способ проброса порта не сработал',
      lastAttemptAt: DateTime.now(),
    ));
    _scheduleRetry();
    return _status;
  }

  Future<MappedPort?> _safeMap(
      NatBackend backend, int internalPort, PortProtocol protocol) async {
    try {
      return await backend.map(
        internalPort: internalPort,
        protocol: protocol,
        lease: _lease,
      );
    } catch (e) {
      log('бэкенд ${backend.method.name} упал на ${protocol.name}: $e',
          name: 'PortMapper');
      return null;
    }
  }

  void _scheduleRenew(MappedPort mapping) {
    _renewTimer?.cancel();
    if (_disposed) return;
    if (mapping.isPermanent) {
      // Бессрочный маппинг продлевать нечем; он переживёт нас, поэтому важно
      // снять его в [unmap].
      return;
    }
    var delay = mapping.lifetime * renewalFraction;
    if (delay < minRenewInterval) delay = minRenewInterval;
    if (delay > maxRenewInterval) delay = maxRenewInterval;
    // Аренда короче минимального интервала: продлеваем на её половине, иначе
    // маппинг протухнет раньше, чем мы проснёмся.
    if (delay > mapping.lifetime) delay = mapping.lifetime ~/ 2;
    _renewTimer = Timer(delay, () {
      unawaited(_attempt());
    });
  }

  void _scheduleRetry() {
    _renewTimer?.cancel();
    if (_disposed) return;
    final index = (_failureCount - 1).clamp(0, retrySchedule.length - 1);
    _renewTimer = Timer(retrySchedule[index], () {
      unawaited(_attempt());
    });
  }

  void _emit(PortMapperStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  /// Снять маппинг. Ошибки шлюза игнорируются — падать на выходе нельзя.
  Future<void> unmap() async {
    _renewTimer?.cancel();
    _renewTimer = null;
    final backend = _active;
    final current = _status;
    if (backend != null) {
      for (var m in [current.tcp, current.udp]) {
        if (m == null) continue;
        try {
          await backend.unmap(m);
        } catch (e) {
          log('не удалось снять маппинг $m: $e', name: 'PortMapper');
        }
      }
    }
    _emit(const PortMapperStatus());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await unmap();
    for (var b in backends) {
      try {
        await b.dispose();
      } catch (e) {
        // Бэкенд, упавший на закрытии, не должен ломать остановку задачи.
      }
    }
    await _statusController.close();
  }
}
