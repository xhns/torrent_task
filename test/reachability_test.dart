import 'dart:io';

import 'package:test/test.dart';
import 'package:torrent_task/src/nat/nat_backend.dart';
import 'package:torrent_task/src/nat/reachability.dart';

void main() {
  group('isPrivateAddress — приватные', () {
    for (final addr in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.1',
      '169.254.5.5',
      '100.64.0.1', // CGNAT, RFC 6598
      '100.127.255.255',
      '::1',
      'fd00::1',
      'fe80::1',
    ]) {
      test('$addr -> true', () {
        expect(isPrivateAddress(InternetAddress(addr)), isTrue);
      });
    }
  });

  group('isPrivateAddress — публичные (включая границы диапазонов)', () {
    for (final addr in [
      '109.195.195.251',
      '8.8.8.8',
      '172.32.0.1', // за границей 172.16/12
      '100.63.255.255', // ниже границы CGNAT
      '100.128.0.1', // выше границы CGNAT
      '2a00::1',
    ]) {
      test('$addr -> false', () {
        expect(isPrivateAddress(InternetAddress(addr)), isFalse);
      });
    }
  });

  group('Reachability.listeningOnConfiguredPort', () {
    test('listenPort == configuredPort -> true', () {
      final r = Reachability(configuredPort: 51413, listenPort: 51413);
      expect(r.listeningOnConfiguredPort, isTrue);
    });

    test('listenPort != configuredPort -> false (взяли эфемерный)', () {
      final r = Reachability(configuredPort: 51413, listenPort: 40001);
      expect(r.listeningOnConfiguredPort, isFalse);
    });
  });

  group('Reachability.incomingConnections', () {
    test('сумма tcp + utp', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        incomingTcpConnections: 3,
        incomingUtpConnections: 5,
      );
      expect(r.incomingConnections, equals(8));
    });
  });

  group('Reachability.effectiveMethod', () {
    test('none + нет входящих с WAN -> none', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        mappingMethod: PortMapMethod.none,
        incomingFromWanConnections: 0,
      );
      expect(r.effectiveMethod, equals(PortMapMethod.none));
    });

    test('none + есть входящие с WAN -> manual (проброшено руками либо NAT нет)', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        mappingMethod: PortMapMethod.none,
        incomingFromWanConnections: 1,
      );
      expect(r.effectiveMethod, equals(PortMapMethod.manual));
    });

    test('natPmp + есть входящие с WAN -> остаётся natPmp', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        mappingMethod: PortMapMethod.natPmp,
        incomingFromWanConnections: 1,
      );
      expect(r.effectiveMethod, equals(PortMapMethod.natPmp),
          reason: 'факт входящих не должен затирать реально сработавший способ маппинга');
    });
  });

  group('Reachability.provenReachable', () {
    test('входящие с LAN не в счёт — только incomingFromWanConnections', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        incomingTcpConnections: 5,
        incomingFromWanConnections: 0,
      );
      // ПРЕДУСЛОВИЕ: входящие вообще были — иначе false ничего бы не доказывал.
      expect(r.incomingConnections, greaterThan(0),
          reason: 'предусловие: входящие соединения реально были (например, сосед по Wi-Fi через LSD)');
      expect(r.provenReachable, isFalse,
          reason: '5 входящих есть, но ни одно не с публичного адреса — это сосед по '
              'Wi-Fi через LSD, а не доказательство проходимости NAT');
    });

    test('хотя бы одно WAN-подключение -> true', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        incomingFromWanConnections: 1,
      );
      expect(r.provenReachable, isTrue);
    });
  });

  group('Reachability.externalEndpoint', () {
    test('адрес и порт есть -> "адрес:порт"', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        externalAddress: InternetAddress('109.195.195.251'),
        externalTcpPort: 51414,
      );
      expect(r.externalEndpoint, equals('109.195.195.251:51414'));
    });

    test('без адреса -> null', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        externalTcpPort: 51414,
      );
      expect(r.externalEndpoint, isNull);
    });

    test('с адресом, но без порта -> null', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        externalAddress: InternetAddress('109.195.195.251'),
      );
      expect(r.externalEndpoint, isNull);
    });
  });

  group('Reachability.toJson', () {
    test('method — это effectiveMethod.name, не сырой mappingMethod', () {
      final r = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        mappingMethod: PortMapMethod.none,
        incomingFromWanConnections: 1,
      );
      // ПРЕДУСЛОВИЕ: effective и сырой mappingMethod действительно разошлись —
      // иначе сравнение с effectiveMethod.name ничего бы не доказывало.
      expect(r.effectiveMethod, isNot(equals(r.mappingMethod)),
          reason: 'предусловие: this test проверяет именно случай, где effective != mapping');

      final json = r.toJson();
      expect(json['method'], equals('manual'));
      expect(json['method'], equals(r.effectiveMethod.name));
      expect(json['provenReachable'], isTrue);
    });
  });

  group('Reachability.copyWith', () {
    test('меняет только переданное поле', () {
      final base = Reachability(
        configuredPort: 51413,
        listenPort: 51413,
        utpPort: 51413,
        mappingMethod: PortMapMethod.natPmp,
        externalAddress: InternetAddress('109.195.195.251'),
        externalTcpPort: 51414,
        incomingTcpConnections: 2,
      );

      final changed = base.copyWith(incomingTcpConnections: 9);

      expect(changed.incomingTcpConnections, equals(9));
      expect(changed.configuredPort, equals(base.configuredPort));
      expect(changed.listenPort, equals(base.listenPort));
      expect(changed.utpPort, equals(base.utpPort));
      expect(changed.mappingMethod, equals(base.mappingMethod));
      expect(changed.externalAddress?.address, equals(base.externalAddress?.address));
      expect(changed.externalTcpPort, equals(base.externalTcpPort));
    });
  });
}
