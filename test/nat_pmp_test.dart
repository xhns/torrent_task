import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:torrent_task/src/nat/nat_backend.dart';
import 'package:torrent_task/src/nat/nat_pmp.dart';

/// Фикстуры сняты дословно с реального роутера (Netcraze NC-1913 /
/// miniupnpd, WAN 109.195.195.251).

/// Ответ на запрос внешнего адреса: version 0, opcode 128, resultCode 0,
/// epoch 1293430 (0x0013bc76), externalAddress 109.195.195.251.
const _extAddrHex = '008000000013bc766dc3c3fb';

/// Ответ на AddMapping TCP: opcode 130, resultCode 0, epoch 1293467,
/// internalPort 51413, externalPort 51414 (!= запрошенного), lifetime 3600.
const _mapTcpHex = '008200000013bc9bc8d5c8d600000e10';

Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  group('buildNatPmpExternalAddressRequest', () {
    test('два байта: версия + опкод', () {
      expect(buildNatPmpExternalAddressRequest(), equals([0, 0]));
    });
  });

  group('buildNatPmpMapRequest — байты по RFC 6886 §3.3', () {
    test('AddMapping TCP', () {
      final req = buildNatPmpMapRequest(
        protocol: PortProtocol.tcp,
        internalPort: 51413,
        externalPort: 51413,
        lifetimeSeconds: 3600,
      );
      expect(
          req,
          equals([
            0x00, 0x02, // version=0, opcode=2 (map TCP)
            0x00, 0x00, // reserved
            0xc8, 0xd5, // internalPort=51413
            0xc8, 0xd5, // externalPort=51413
            0x00, 0x00, 0x0e, 0x10, // lifetime=3600
          ]),
          reason: 'опкод TCP=2, порты и lifetime — big-endian по месту');
      expect(req, hasLength(12));
    });

    test('AddMapping UDP — опкод 1', () {
      final req = buildNatPmpMapRequest(
        protocol: PortProtocol.udp,
        internalPort: 51413,
        externalPort: 51413,
        lifetimeSeconds: 3600,
      );
      expect(
          req,
          equals([
            0x00, 0x01,
            0x00, 0x00,
            0xc8, 0xd5,
            0xc8, 0xd5,
            0x00, 0x00, 0x0e, 0x10,
          ]),
          reason: 'единственная разница с TCP-запросом — опкод 1 вместо 2');
    });

    test('запрос на снятие: externalPort=0, lifetime=0', () {
      final req = buildNatPmpMapRequest(
        protocol: PortProtocol.tcp,
        internalPort: 51413,
        externalPort: 0,
        lifetimeSeconds: 0,
      );
      expect(
          req,
          equals([
            0x00, 0x02,
            0x00, 0x00,
            0xc8, 0xd5, // internalPort остаётся прежним — иначе шлюз не поймёт, что удалять
            0x00, 0x00, // externalPort=0
            0x00, 0x00, 0x00, 0x00, // lifetime=0
          ]),
          reason: 'снятие — тот же формат запроса с обнулёнными externalPort и lifetime');
    });
  });

  group('parseNatPmpExternalAddressResponse — реальная фикстура', () {
    test('разбирает все поля', () {
      final parsed = parseNatPmpExternalAddressResponse(_hex(_extAddrHex));
      expect(parsed, isNotNull);
      expect(parsed!.resultCode, equals(0));
      expect(parsed.isSuccess, isTrue);
      expect(parsed.epochSeconds, equals(1293430));
      expect(parsed.externalAddress, isNotNull);
      expect(parsed.externalAddress!.address, equals('109.195.195.251'));
    });

    test('отказ (resultCode=2, not authorized): адрес не выдумывается', () {
      // version=0, opcode=128, resultCode=2, epoch=1234, "адрес" — мусорные
      // байты, которые парсер обязан проигнорировать: при ненулевом коде
      // поле адреса не определено протоколом.
      final data = Uint8List.fromList(
          [0x00, 0x80, 0x00, 0x02, 0x00, 0x00, 0x04, 0xd2, 0xaa, 0xbb, 0xcc, 0xdd]);
      final parsed = parseNatPmpExternalAddressResponse(data);
      expect(parsed, isNotNull);
      expect(parsed!.isSuccess, isFalse);
      expect(parsed.externalAddress, isNull,
          reason: 'при resultCode != 0 код намеренно не читает поле адреса');
    });

    test('пустой массив -> null', () {
      expect(parseNatPmpExternalAddressResponse(Uint8List(0)), isNull);
    });

    test('слишком короткий пакет (11 байт) -> null', () {
      expect(parseNatPmpExternalAddressResponse(Uint8List(11)), isNull);
    });

    test('неверная версия -> null', () {
      final data = _hex(_extAddrHex);
      data[0] = 1; // версия должна быть 0
      expect(parseNatPmpExternalAddressResponse(data), isNull);
    });

    test('неверный опкод -> null', () {
      final data = _hex(_extAddrHex);
      data[1] = 129; // это опкод ответа на маппинг UDP, не ext-addr
      expect(parseNatPmpExternalAddressResponse(data), isNull);
    });
  });

  group('parseNatPmpMapResponse — реальная фикстура', () {
    test('разбирает все поля, включая расхождение портов', () {
      final parsed = parseNatPmpMapResponse(_hex(_mapTcpHex));
      expect(parsed, isNotNull);
      expect(parsed!.resultCode, equals(0));
      expect(parsed.isSuccess, isTrue);
      expect(parsed.epochSeconds, equals(1293467));
      expect(parsed.internalPort, equals(51413));
      expect(parsed.externalPort, equals(51414),
          reason: 'шлюз выдал ВНЕШНИЙ порт, отличный от запрошенного (51413 был занят '
              'на самом шлюзе) — это реальный кейс со стенда, не гипотетический');
      expect(parsed.lifetimeSeconds, equals(3600));
      expect(parsed.protocol, equals(PortProtocol.tcp));
    });

    test('UDP-ответ (опкод 129) разбирается с protocol == udp', () {
      final data = _hex(_mapTcpHex);
      data[1] = 129; // opMapUdp(1) + responseFlag(128)
      final parsed = parseNatPmpMapResponse(data);
      expect(parsed, isNotNull);
      expect(parsed!.protocol, equals(PortProtocol.udp));
    });

    test('отказ (resultCode=2, not authorized)', () {
      final data = _hex(_mapTcpHex);
      // resultCode — uint16 по смещению 2..3.
      data[2] = 0x00;
      data[3] = 0x02;
      final parsed = parseNatPmpMapResponse(data);
      expect(parsed, isNotNull);
      expect(parsed!.isSuccess, isFalse);
    });

    test('пустой массив -> null', () {
      expect(parseNatPmpMapResponse(Uint8List(0)), isNull);
    });

    test('слишком короткий пакет (15 байт) -> null', () {
      expect(parseNatPmpMapResponse(Uint8List(15)), isNull);
    });

    test('неверная версия -> null', () {
      final data = _hex(_mapTcpHex);
      data[0] = 1;
      expect(parseNatPmpMapResponse(data), isNull);
    });

    test('неверный опкод (не 129/130) -> null', () {
      final data = _hex(_mapTcpHex);
      data[1] = 128; // опкод ответа на ext-addr, не на маппинг
      expect(parseNatPmpMapResponse(data), isNull);
    });
  });

  group('NatPmpResult.describe', () {
    test('известные коды не отдают "unknown"', () {
      for (final code in [
        NatPmpResult.success,
        NatPmpResult.unsupportedVersion,
        NatPmpResult.notAuthorized,
        NatPmpResult.networkFailure,
        NatPmpResult.outOfResources,
        NatPmpResult.unsupportedOpcode,
      ]) {
        expect(NatPmpResult.describe(code), isNot(contains('unknown')),
            reason: 'код $code задокументирован в RFC 6886 §3.5 — должен иметь свой текст');
      }
    });

    test('неизвестный код содержит сам код в тексте', () {
      expect(NatPmpResult.describe(99), contains('99'));
    });
  });
}
