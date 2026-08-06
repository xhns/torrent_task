import 'dart:io';

import 'package:test/test.dart';
import 'package:torrent_task/src/nat/gateway.dart';

/// Реальный `/proc/net/route` с рабочей машины (разделители — табы).
/// Default route (Destination=00000000) ведёт на 192.168.1.51 через eth1;
/// остальные три строки — на другие подсети (tun0 x2, wgagent), не default.
const _procNetRoute = 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n'
    'eth1\t00000000\t3301A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'
    'tun0\t0000040A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n'
    'tun0\t0000050A\t0100040A\t0003\t0\t0\t0\t00FFFFFF\t0\t0\t0\n'
    'wgagent\t0000070A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n';

const _procNetRouteHeader = 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT';

void main() {
  group('parseProcNetRoute', () {
    test('реальная фикстура -> ровно один адрес, 192.168.1.51', () {
      final gateways = parseProcNetRoute(_procNetRoute);
      expect(gateways, hasLength(1));
      expect(gateways.single.address, equals('192.168.1.51'),
          reason: 'hex 3301A8C0 — little-endian: наивное чтение слева направо '
              '(байт за байтом как есть) дало бы 51.1.168.192, а не 192.168.1.51');
    });

    test('строки с Destination != 0 игнорируются (их три в фикстуре)', () {
      // Только не-default строки из фикстуры (tun0 x2, wgagent), без строки
      // eth1: без фильтра по Destination они дали бы непустой результат.
      final content = '$_procNetRouteHeader\n'
          'tun0\t0000040A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n'
          'tun0\t0000050A\t0100040A\t0003\t0\t0\t0\t00FFFFFF\t0\t0\t0\n'
          'wgagent\t0000070A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n';
      expect(parseProcNetRoute(content), isEmpty,
          reason: 'Destination != 0 у всех трёх строк — ни одна не default-маршрут');
    });

    test('default-маршрут с Gateway == 0 (on-link) игнорируется', () {
      final content = '$_procNetRouteHeader\n'
          'eth0\t00000000\t00000000\t0001\t0\t0\t0\t00000000\t0\t0\t0\n';
      final gateways = parseProcNetRoute(content);
      expect(gateways, isEmpty,
          reason: 'Gateway=0 значит on-link default — шлюза как отдельного узла нет');
    });

    test('шапка не ломает разбор', () {
      final content = '$_procNetRouteHeader\n'
          'eth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n';
      final gateways = parseProcNetRoute(content);
      expect(gateways.single.address, equals('192.168.1.1'));
    });

    test('пустая строка и мусорная строка игнорируются', () {
      final content = '$_procNetRouteHeader\n'
          '\n'
          'этой строке в /proc/net/route взяться неоткуда, но парсер обязан выжить\n'
          'eth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n';
      final gateways = parseProcNetRoute(content);
      expect(gateways.single.address, equals('192.168.1.1'));
    });

    test('дубли схлопываются', () {
      final content = '$_procNetRouteHeader\n'
          'eth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n'
          'eth1\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n';
      final gateways = parseProcNetRoute(content);
      expect(gateways, hasLength(1),
          reason: 'две default-строки с одинаковым шлюзом — один адрес на выходе');
    });
  });

  group('parseRouteGetDefault (macOS `route -n get default`)', () {
    const output = '   route to: default\n'
        'destination: default\n'
        '       mask: default\n'
        '    gateway: 192.168.1.1\n'
        '  interface: en0\n'
        '      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>\n';

    test('извлекает адрес шлюза', () {
      final gw = parseRouteGetDefault(output);
      expect(gw, isNotNull);
      expect(gw!.address, equals('192.168.1.1'));
    });

    test('вывод без строки gateway: -> null', () {
      const noGateway = '   route to: default\n'
          'destination: default\n'
          '  interface: en0\n';
      expect(parseRouteGetDefault(noGateway), isNull);
    });

    test('gateway: 127.0.0.1 -> null (loopback не годится в шлюзы)', () {
      const loopback = '   route to: default\n'
          '    gateway: 127.0.0.1\n'
          '  interface: lo0\n';
      expect(parseRouteGetDefault(loopback), isNull);
    });
  });

  group('isUsableGatewayAddress', () {
    test('обычный LAN-адрес годится', () {
      expect(isUsableGatewayAddress(InternetAddress('192.168.1.1')), isTrue);
    });

    test('loopback не годится', () {
      expect(isUsableGatewayAddress(InternetAddress('127.0.0.1')), isFalse);
    });

    test('"любой" адрес не годится', () {
      expect(isUsableGatewayAddress(InternetAddress('0.0.0.0')), isFalse);
    });

    test('link-local (169.254/16) не годится', () {
      expect(isUsableGatewayAddress(InternetAddress('169.254.1.1')), isFalse);
    });

    test('мультикаст не годится', () {
      expect(isUsableGatewayAddress(InternetAddress('224.0.0.1')), isFalse);
      expect(isUsableGatewayAddress(InternetAddress('239.255.255.250')), isFalse);
    });
  });

  group('subnetGatewayGuesses', () {
    test('догадка .1 по каждой подсети, кроме той, где мы сами .1', () {
      final locals = [
        InternetAddress('192.168.1.56'),
        InternetAddress('172.17.0.1'),
        InternetAddress('10.4.0.6'),
      ];
      final guesses = subnetGatewayGuesses(locals).map((a) => a.address).toSet();

      expect(guesses, containsAll(['192.168.1.1', '10.4.0.1']));
      expect(guesses, isNot(contains('172.17.0.1')),
          reason: '172.17.0.1 сам является .1 своей подсети — самому себе шлюз не назначаем');
    });

    test('пустой вход -> пустой результат', () {
      expect(subnetGatewayGuesses(const []), isEmpty);
    });

    test('дубли из одной подсети схлопываются', () {
      final locals = [
        InternetAddress('192.168.1.56'),
        InternetAddress('192.168.1.57'),
      ];
      final guesses = subnetGatewayGuesses(locals);
      expect(guesses, hasLength(1));
      expect(guesses.single.address, equals('192.168.1.1'));
    });
  });

  group('pickLocalAddressFor — выбор по самому длинному префиксу', () {
    final locals = [
      InternetAddress('172.17.0.1'),
      InternetAddress('192.168.1.56'),
      InternetAddress('10.4.0.6'),
    ];

    test('шлюз 192.168.1.1 -> локальный 192.168.1.56, не первый в списке', () {
      final picked = pickLocalAddressFor(InternetAddress('192.168.1.1'), locals);
      expect(picked, isNotNull);
      expect(picked!.address, equals('192.168.1.56'),
          reason: 'на машине с docker-мостами (172.17.0.1 первый в списке) '
              '«первый попавшийся» промахнулся бы мимо реального LAN-интерфейса');
    });

    test('шлюз 10.4.0.1 -> локальный 10.4.0.6', () {
      final picked = pickLocalAddressFor(InternetAddress('10.4.0.1'), locals);
      expect(picked, isNotNull);
      expect(picked!.address, equals('10.4.0.6'));
    });

    test('пустой список locals -> null', () {
      expect(pickLocalAddressFor(InternetAddress('192.168.1.1'), const []), isNull);
    });
  });
}
