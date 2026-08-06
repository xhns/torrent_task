import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

/// Фасад [PortMapper]: выбор бэкенда, продление аренды, снятие маппинга.
///
/// Всё на подставных бэкендах — тесты НЕ ходят в сеть. Это принципиально:
/// в сети разработчика живой роутер, и тест, дёрнувший настоящий UPnP, оставил
/// бы на нём реальный проброс порта.
void main() {
  group('PortMapper — выбор бэкенда', () {
    test('первый способный бэкенд становится активным, остальные не трогаем',
        () async {
      final upnp = _FakeBackend(PortMapMethod.upnpIgd);
      final pmp = _FakeBackend(PortMapMethod.natPmp);
      final mapper = _mapper([upnp, pmp]);

      final result = await mapper.map(internalPort: 51413);

      expect(result, isNotNull, reason: 'предусловие: маппинг получен');
      expect(result!.method, equals(PortMapMethod.upnpIgd));
      expect(mapper.status.method, equals(PortMapMethod.upnpIgd));
      expect(pmp.mapCalls, isEmpty,
          reason: 'второй бэкенд не должен опрашиваться, пока первый работает');

      await mapper.dispose();
    });

    test('неработающий бэкенд уступает следующему', () async {
      final upnp = _FakeBackend(PortMapMethod.upnpIgd, tcpWorks: false)
        ..lastError = 'IGD не найден';
      final pmp = _FakeBackend(PortMapMethod.natPmp);
      final mapper = _mapper([upnp, pmp]);

      final result = await mapper.map(internalPort: 51413);

      expect(upnp.mapCalls, isNotEmpty,
          reason: 'предусловие: первый бэкенд действительно пробовали');
      expect(result?.method, equals(PortMapMethod.natPmp));
      expect(mapper.status.method, equals(PortMapMethod.natPmp));

      await mapper.dispose();
    });

    test('бэкенд, бросивший исключение, не роняет фасад', () async {
      final broken = _FakeBackend(PortMapMethod.upnpIgd, throwOnMap: true);
      final pmp = _FakeBackend(PortMapMethod.natPmp);
      final mapper = _mapper([broken, pmp]);

      final result = await mapper.map(internalPort: 51413);

      expect(result?.method, equals(PortMapMethod.natPmp),
          reason: 'падение одного способа — не повод остаться без порта');

      await mapper.dispose();
    });

    test('никто не смог — статус none с причиной и запланированный повтор',
        () async {
      final a = _FakeBackend(PortMapMethod.upnpIgd, tcpWorks: false, udpWorks: false)
        ..lastError = 'IGD не найден';
      final b = _FakeBackend(PortMapMethod.natPmp, tcpWorks: false, udpWorks: false)
        ..lastError = 'шлюз молчит';
      final mapper = _mapper([a, b],
          retrySchedule: const [Duration(milliseconds: 30)]);

      final result = await mapper.map(internalPort: 51413);

      expect(result, isNull);
      expect(mapper.status.method, equals(PortMapMethod.none));
      expect(mapper.status.error, contains('шлюз молчит'));

      final before = a.mapCalls.length;
      await Future.delayed(const Duration(milliseconds: 120));
      expect(a.mapCalls.length, greaterThan(before),
          reason: 'после неудачи фасад обязан пробовать снова, '
              'иначе роутер, поднявшийся через минуту, останется неиспользован');

      await mapper.dispose();
    });
  });

  group('PortMapper — TCP и UDP', () {
    test('просим оба протокола: маппятся оба, наружу отдаётся TCP', () async {
      final backend = _FakeBackend(PortMapMethod.natPmp);
      final mapper = _mapper([backend]);

      final result = await mapper.map(internalPort: 51413);

      expect(backend.mapCalls.map((c) => c.protocol),
          containsAll([PortProtocol.tcp, PortProtocol.udp]));
      expect(result!.protocol, equals(PortProtocol.tcp));
      expect(mapper.status.tcp, isNotNull);
      expect(mapper.status.udp, isNotNull);
      expect(mapper.status.error, isNull);

      await mapper.dispose();
    });

    test('UDP не проброшен при живом TCP — это отражено в статусе, а не молчок',
        () async {
      final backend = _FakeBackend(PortMapMethod.natPmp, udpWorks: false)
        ..lastError = 'UDP-маппинг запрещён';
      final mapper = _mapper([backend]);

      final result = await mapper.map(internalPort: 51413);

      expect(result, isNotNull, reason: 'предусловие: TCP всё-таки проброшен');
      expect(mapper.status.udp, isNull);
      expect(mapper.status.error, isNotNull,
          reason: 'без UDP входящий uTP до нас не дойдёт — пользователь '
              'должен это увидеть, а не гадать');

      await mapper.dispose();
    });

    test('внешний порт может отличаться от внутреннего и отдаётся наружу как есть',
        () async {
      // Не выдумка: на реальном роутере запрос внутреннего 51413 вернул
      // внешний 51414, потому что 51413 на шлюзе был занят.
      final backend = _FakeBackend(PortMapMethod.natPmp, externalPortShift: 1);
      final mapper = _mapper([backend]);

      final result = await mapper.map(internalPort: 51413);

      expect(result!.internalPort, equals(51413));
      expect(result.externalPort, equals(51414));
      expect(mapper.status.externalTcpPort, equals(51414));

      await mapper.dispose();
    });
  });

  group('PortMapper — аренда', () {
    test('аренда продлевается ДО истечения, а не после', () async {
      final backend = _FakeBackend(PortMapMethod.natPmp,
          grantedLease: const Duration(milliseconds: 200));
      final mapper = _mapper([backend],
          minRenewInterval: const Duration(milliseconds: 10),
          maxRenewInterval: const Duration(seconds: 5));

      await mapper.map(internalPort: 51413);
      final firstRoundTcp =
          backend.mapCalls.where((c) => c.protocol == PortProtocol.tcp).length;
      expect(firstRoundTcp, equals(1),
          reason: 'предусловие: первичный маппинг сделан ровно один раз');

      // Половина срока — 100 мс. Ждём заметно меньше полного срока аренды:
      // если продление привязано к истечению, а не к половине, здесь ничего
      // не произойдёт.
      await Future.delayed(const Duration(milliseconds: 160));

      final renewedTcp =
          backend.mapCalls.where((c) => c.protocol == PortProtocol.tcp).length;
      expect(renewedTcp, greaterThan(firstRoundTcp),
          reason: 'аренду обязаны продлить раньше её истечения, иначе окно '
              'между протуханием и продлением клиент недостижим');

      await mapper.dispose();
    });

    test('бессрочный маппинг не продлевается, но снимается', () async {
      final backend =
          _FakeBackend(PortMapMethod.upnpIgd, grantedLease: Duration.zero);
      final mapper = _mapper([backend],
          minRenewInterval: const Duration(milliseconds: 10));

      final result = await mapper.map(internalPort: 51413);
      expect(result!.isPermanent, isTrue,
          reason: 'предусловие: шлюз выдал бессрочный маппинг');
      final calls = backend.mapCalls.length;

      await Future.delayed(const Duration(milliseconds: 120));
      expect(backend.mapCalls.length, equals(calls),
          reason: 'бессрочную аренду продлевать нечем и незачем');

      await mapper.unmap();
      expect(backend.unmapCalls, isNotEmpty,
          reason: 'бессрочный маппинг переживёт процесс — снять его '
              'обязательно, иначе порт останется висеть на шлюзе');

      await mapper.dispose();
    });
  });

  group('PortMapper — снятие', () {
    test('unmap снимает оба протокола и обнуляет статус', () async {
      final backend = _FakeBackend(PortMapMethod.natPmp);
      final mapper = _mapper([backend]);
      await mapper.map(internalPort: 51413);
      expect(mapper.status.isMapped, isTrue,
          reason: 'предусловие: было что снимать');

      await mapper.unmap();

      expect(backend.unmapCalls.map((m) => m.protocol),
          containsAll([PortProtocol.tcp, PortProtocol.udp]));
      expect(mapper.status.isMapped, isFalse);
      expect(mapper.status.method, equals(PortMapMethod.none));

      await mapper.dispose();
    });

    test('после unmap продление не срабатывает', () async {
      final backend = _FakeBackend(PortMapMethod.natPmp,
          grantedLease: const Duration(milliseconds: 100));
      final mapper = _mapper([backend],
          minRenewInterval: const Duration(milliseconds: 10));
      await mapper.map(internalPort: 51413);
      await mapper.unmap();
      final calls = backend.mapCalls.length;

      await Future.delayed(const Duration(milliseconds: 150));
      expect(backend.mapCalls.length, equals(calls),
          reason: 'снятый маппинг не должен воскресать по таймеру');

      await mapper.dispose();
    });

    test('dispose закрывает бэкенды и поток статуса', () async {
      final backend = _FakeBackend(PortMapMethod.natPmp);
      final mapper = _mapper([backend]);
      await mapper.map(internalPort: 51413);

      await mapper.dispose();

      expect(backend.disposed, isTrue);
      expect(mapper.onStatus, emitsDone);
    });
  });

  group('PortMapper — поток статуса', () {
    test('о полученном маппинге сообщается подписчику', () async {
      final backend = _FakeBackend(PortMapMethod.natPmp);
      final mapper = _mapper([backend]);
      final seen = <PortMapperStatus>[];
      final sub = mapper.onStatus.listen(seen.add);

      await mapper.map(internalPort: 51413);
      await Future.delayed(Duration.zero);

      expect(seen, isNotEmpty);
      expect(seen.last.method, equals(PortMapMethod.natPmp));
      expect(seen.last.externalTcpPort, equals(51413));

      await sub.cancel();
      await mapper.dispose();
    });
  });
}

PortMapper _mapper(
  List<NatBackend> backends, {
  Duration minRenewInterval = const Duration(seconds: 60),
  Duration maxRenewInterval = const Duration(minutes: 30),
  List<Duration> retrySchedule = const [Duration(minutes: 10)],
}) {
  return PortMapper(
    backends: backends,
    minRenewInterval: minRenewInterval,
    maxRenewInterval: maxRenewInterval,
    retrySchedule: retrySchedule,
  );
}

class _MapCall {
  final int internalPort;
  final PortProtocol protocol;
  final Duration lease;

  _MapCall(this.internalPort, this.protocol, this.lease);
}

class _FakeBackend implements NatBackend {
  @override
  final PortMapMethod method;

  final bool tcpWorks;
  final bool udpWorks;
  final bool throwOnMap;
  final Duration grantedLease;
  final int externalPortShift;

  final List<_MapCall> mapCalls = [];
  final List<MappedPort> unmapCalls = [];
  bool disposed = false;

  @override
  String? lastError;

  _FakeBackend(
    this.method, {
    this.tcpWorks = true,
    this.udpWorks = true,
    this.throwOnMap = false,
    this.grantedLease = const Duration(seconds: 3600),
    this.externalPortShift = 0,
  });

  @override
  Future<MappedPort?> map({
    required int internalPort,
    required PortProtocol protocol,
    required Duration lease,
    int? suggestedExternalPort,
  }) async {
    mapCalls.add(_MapCall(internalPort, protocol, lease));
    if (throwOnMap) throw StateError('бэкенд сломан');
    final ok = protocol == PortProtocol.tcp ? tcpWorks : udpWorks;
    if (!ok) return null;
    return MappedPort(
      method: method,
      protocol: protocol,
      internalPort: internalPort,
      externalPort: internalPort + externalPortShift,
      externalAddress: InternetAddress('109.195.195.251'),
      lifetime: grantedLease,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<bool> unmap(MappedPort mapping) async {
    unmapCalls.add(mapping);
    return true;
  }

  @override
  Future<InternetAddress?> externalAddress() async =>
      InternetAddress('109.195.195.251');

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
