import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:torrent_task/src/nat/nat_backend.dart';
import 'package:torrent_task/src/nat/pcp.dart';

/// Реальный ответ PCP ANNOUNCE (opcode 0) со стенда — используется как
/// негативный кейс для parsePcpMapResponse: опкод не MAP и длина < 60.
const _announceHex = '02800000000000000013bc76000000000000000000000000';

Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

/// Собирает синтетический корректный ответ MAP (60 байт, RFC 6887 §7.1 +
/// §11.1) с явно расставленными полями по смещениям — независимо от
/// buildPcpMapRequest, чтобы не проверять код тем же кодом.
Uint8List _buildMapResponse({
  int version = pcpVersion,
  int opcodeByte = pcpOpcodeMap | pcpResponseFlag,
  int resultCode = PcpResult.success,
  int lifetimeSeconds = 3600,
  int epochSeconds = 1293467,
  List<int>? nonce,
  int protocolByte = 6, // TCP
  int internalPort = 51413,
  int externalPort = 51414,
  List<int>? externalAddressMapped,
}) {
  final out = Uint8List(pcpMapPacketLength);
  final b = ByteData.sublistView(out);
  b.setUint8(0, version);
  b.setUint8(1, opcodeByte);
  b.setUint8(2, 0); // reserved
  b.setUint8(3, resultCode);
  b.setUint32(4, lifetimeSeconds);
  b.setUint32(8, epochSeconds);
  // 12..23 — reserved, оставляем нулями.
  out.setRange(24, 36, nonce ?? List<int>.generate(12, (i) => i + 1));
  b.setUint8(36, protocolByte);
  b.setUint8(37, 0);
  b.setUint8(38, 0);
  b.setUint8(39, 0);
  b.setUint16(40, internalPort);
  b.setUint16(42, externalPort);
  out.setRange(
      44,
      60,
      externalAddressMapped ??
          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 109, 195, 195, 251]);
  return out;
}

void main() {
  group('pcpEncodeAddress', () {
    test('IPv4 -> IPv4-mapped (::ffff:a.b.c.d), 16 байт', () {
      final encoded = pcpEncodeAddress(InternetAddress('192.168.1.56'));
      expect(
          encoded,
          equals([
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 10 нулевых байт
            0xff, 0xff, // IPv4-mapped маркер
            0xc0, 0xa8, 0x01, 0x38, // 192.168.1.56
          ]));
      expect(encoded, hasLength(16));
    });

    test('IPv6-адрес отдаётся как есть (16 байт rawAddress)', () {
      final address = InternetAddress('2001:db8::1');
      final encoded = pcpEncodeAddress(address);
      expect(encoded, equals(address.rawAddress));
      expect(encoded, hasLength(16));
    });
  });

  group('pcpDecodeAddress', () {
    test('IPv4-mapped разворачивается обратно в IPv4', () {
      final bytes = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xff, 0xff,
        109, 195, 195, 251,
      ];
      final decoded = pcpDecodeAddress(bytes);
      expect(decoded.type, equals(InternetAddressType.IPv4));
      expect(decoded.address, equals('109.195.195.251'));
    });

    test('настоящий IPv6 остаётся IPv6', () {
      final address = InternetAddress('2001:db8::1');
      final decoded = pcpDecodeAddress(address.rawAddress);
      expect(decoded.type, equals(InternetAddressType.IPv6));
      expect(decoded.address, equals(address.address));
    });
  });

  group('buildPcpMapRequest — байты по RFC 6887 §7.1/§11.1', () {
    final nonce = Uint8List.fromList(List<int>.generate(12, (i) => i));
    final clientAddress = InternetAddress('192.168.1.56');

    test('длина ровно 60 байт, поля по смещениям', () {
      final req = buildPcpMapRequest(
        nonce: nonce,
        protocol: PortProtocol.tcp,
        internalPort: 51413,
        suggestedExternalPort: 51414,
        clientAddress: clientAddress,
        lifetimeSeconds: 7200,
      );

      expect(req, hasLength(60));
      expect(req[0], equals(2), reason: 'version');
      expect(req[1], equals(1), reason: 'opcode MAP, R=0 (запрос)');
      expect(req.sublist(2, 4), equals([0, 0]), reason: 'reserved');
      expect(req.sublist(4, 8), equals([0x00, 0x00, 0x1c, 0x20]),
          reason: 'lifetime=7200 big-endian');
      expect(
          req.sublist(8, 24),
          equals([
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0xff, 0xff,
            0xc0, 0xa8, 0x01, 0x38, // 192.168.1.56
          ]),
          reason: 'клиентский адрес — IPv4-mapped 192.168.1.56');
      expect(req.sublist(24, 36), equals(nonce), reason: 'nonce');
      expect(req[36], equals(6), reason: 'protocol=6 (TCP, IANA)');
      expect(req.sublist(37, 40), equals([0, 0, 0]), reason: 'reserved (24 бита)');
      expect(req.sublist(40, 42), equals([0xc8, 0xd5]), reason: 'internalPort=51413');
      expect(req.sublist(42, 44), equals([0xc8, 0xd6]), reason: 'suggestedExternalPort=51414');
      expect(
          req.sublist(44, 60),
          equals([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0]),
          reason: 'без suggestedExternalAddress используется 0.0.0.0 (anyIPv4), тоже mapped');
    });

    test('UDP -> protocol byte 17', () {
      final req = buildPcpMapRequest(
        nonce: nonce,
        protocol: PortProtocol.udp,
        internalPort: 51413,
        suggestedExternalPort: 51413,
        clientAddress: clientAddress,
        lifetimeSeconds: 3600,
      );
      expect(req[36], equals(17));
    });

    test('nonce неправильной длины -> ArgumentError', () {
      expect(
          () => buildPcpMapRequest(
                nonce: Uint8List(11),
                protocol: PortProtocol.tcp,
                internalPort: 51413,
                suggestedExternalPort: 51413,
                clientAddress: clientAddress,
                lifetimeSeconds: 3600,
              ),
          throwsArgumentError);
    });
  });

  group('parsePcpMapResponse', () {
    test('реальный ANNOUNCE со стенда -> null (не MAP, короче 60 байт)', () {
      expect(parsePcpMapResponse(_hex(_announceHex)), isNull);
    });

    test('синтетический корректный ответ MAP -> все поля', () {
      final nonce = List<int>.generate(12, (i) => i + 1);
      final parsed = parsePcpMapResponse(_buildMapResponse(nonce: nonce));

      expect(parsed, isNotNull);
      expect(parsed!.resultCode, equals(0));
      expect(parsed.isSuccess, isTrue);
      expect(parsed.lifetimeSeconds, equals(3600));
      expect(parsed.epochSeconds, equals(1293467));
      expect(parsed.nonce, equals(nonce));
      expect(parsed.protocol, equals(PortProtocol.tcp));
      expect(parsed.internalPort, equals(51413));
      expect(parsed.externalPort, equals(51414));
      expect(parsed.externalAddress.address, equals('109.195.195.251'));
    });

    test('ADDRESS_MISMATCH (12) -> isSuccess=false, описание осмысленное', () {
      final parsed = parsePcpMapResponse(_buildMapResponse(resultCode: 12));
      expect(parsed, isNotNull);
      expect(parsed!.isSuccess, isFalse);
      expect(parsed.resultCode, equals(12));
      expect(PcpResult.describe(12), isNot(equals('unknown result code 12')),
          reason: '12 (ADDRESS_MISMATCH) задокументирован в RFC 6887 §7.4');
      expect(PcpResult.describe(12), contains('шлюз'));
    });

    test('неизвестный номер протокола -> protocol == null', () {
      final parsed = parsePcpMapResponse(_buildMapResponse(protocolByte: 132));
      expect(parsed, isNotNull);
      expect(parsed!.protocol, isNull);
    });

    test('длина 59 -> null', () {
      final full = _buildMapResponse();
      expect(parsePcpMapResponse(Uint8List.fromList(full.sublist(0, 59))), isNull);
    });

    test('неверная версия (1 вместо 2) -> null', () {
      expect(parsePcpMapResponse(_buildMapResponse(version: 1)), isNull);
    });

    test('R не выставлен (это запрос, не ответ) -> null', () {
      // opcodeByte = pcpOpcodeMap без pcpResponseFlag: [1] = 0x01.
      expect(
          parsePcpMapResponse(_buildMapResponse(opcodeByte: pcpOpcodeMap)), isNull,
          reason: 'старший бит не поднят — это исходящий запрос, а не ответ шлюза');
    });
  });

  group('generatePcpNonce', () {
    test('длина 12 байт', () {
      expect(generatePcpNonce(Random(1)), hasLength(pcpNonceLength));
    });

    test('разные генераторы дают разные nonce', () {
      final a = generatePcpNonce(Random(1));
      final b = generatePcpNonce(Random(2));
      expect(a, isNot(equals(b)));
    });
  });
}
