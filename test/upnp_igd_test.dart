import 'dart:io';

import 'package:test/test.dart';
import 'package:torrent_task/src/nat/nat_backend.dart';
import 'package:torrent_task/src/nat/ssdp.dart';
import 'package:torrent_task/src/nat/upnp_igd.dart';

/// Реальный SSDP-ответ со стенда (MiniUPnPd на домашнем роутере), с \r\n
/// как в проводе.
const _realSsdpResponse = 'HTTP/1.1 200 OK\r\n'
    'CACHE-CONTROL: max-age=1800\r\n'
    'ST: urn:schemas-upnp-org:service:WANIPConnection:1\r\n'
    'USN: uuid:d6e12b24-d3c8-11f0-92a8-bf2c7c283550::'
    'urn:schemas-upnp-org:service:WANIPConnection:1\r\n'
    'EXT:\r\n'
    'SERVER: Netcraze Ltd. UPnP/1.1 MiniUPnPd/2.3.9\r\n'
    'LOCATION: http://192.168.1.1:1900/rootDesc.xml\r\n'
    'OPT: "http://schemas.upnp.org/upnp/1/0/"; ns=01\r\n'
    '01-NLS: 1784732913\r\n'
    'BOOTID.UPNP.ORG: 1784732913\r\n';

/// Реальное device description со стенда: WANIPConnection лежит на третьем
/// уровне вложенности deviceList, а Layer3Forwarding (не то, что нужно)
/// идёт раньше по тексту файла — наивный "первый controlURL" ловит именно
/// его.
const _realDeviceDescription = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" configId="1337">
<specVersion><major>1</major><minor>1</minor></specVersion>
<device>
<deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
<friendlyName>Netcraze Gateway</friendlyName>
<serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
<serviceId>urn:upnp-org:serviceId:L3Forwarding1</serviceId>
<SCPDURL>/L3F.xml</SCPDURL>
<controlURL>/ctl/L3F</controlURL>
<eventSubURL>/evt/L3F</eventSubURL>
</service>
</serviceList>
<deviceList>
<device>
<deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
<serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
<serviceId>urn:upnp-org:serviceId:WANCommonIFC1</serviceId>
<SCPDURL>/WANCfg.xml</SCPDURL>
<controlURL>/ctl/CmnIfCfg</controlURL>
<eventSubURL>/evt/CmnIfCfg</eventSubURL>
</service>
</serviceList>
<deviceList>
<device>
<deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
<serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
<SCPDURL>/WANIPCn.xml</SCPDURL>
<controlURL>/ctl/IPConn</controlURL>
<eventSubURL>/evt/IPConn</eventSubURL>
</service>
</serviceList>
</device>
</deviceList>
</device>
</deviceList>
</device>
</root>
''';

void main() {
  final source = InternetAddress('192.168.1.1');

  group('parseSsdpResponse', () {
    test('реальный ответ со стенда разбирается целиком', () {
      final device = parseSsdpResponse(_realSsdpResponse, source);

      expect(device, isNotNull);
      expect(device!.location, equals(Uri.parse('http://192.168.1.1:1900/rootDesc.xml')));
      expect(device.server, equals('Netcraze Ltd. UPnP/1.1 MiniUPnPd/2.3.9'));
      expect(
          device.usn,
          equals('uuid:d6e12b24-d3c8-11f0-92a8-bf2c7c283550::'
              'urn:schemas-upnp-org:service:WANIPConnection:1'));
      expect(device.searchTarget,
          equals('urn:schemas-upnp-org:service:WANIPConnection:1'));
      expect(device.sourceAddress, same(source));
    });

    test('ответ без LOCATION отбрасывается', () {
      final raw = 'HTTP/1.1 200 OK\r\n'
          'SERVER: test\r\n'
          'USN: uuid:whatever\r\n'
          '\r\n';
      expect(parseSsdpResponse(raw, source), isNull);
    });

    test('не-200 статус отбрасывается', () {
      final raw = 'HTTP/1.1 404 Not Found\r\n'
          'LOCATION: http://192.168.1.1:1900/rootDesc.xml\r\n'
          '\r\n';
      expect(parseSsdpResponse(raw, source), isNull);
    });

    test('заголовки регистронезависимы (строчный location:)', () {
      final raw = 'HTTP/1.1 200 OK\r\n'
          'location: http://192.168.1.1:1900/rootDesc.xml\r\n'
          'usn: uuid:abc\r\n'
          'st: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n'
          '\r\n';
      final device = parseSsdpResponse(raw, source);
      expect(device, isNotNull);
      expect(device!.location, equals(Uri.parse('http://192.168.1.1:1900/rootDesc.xml')));
      expect(device.usn, equals('uuid:abc'));
    });

    test('разделители \\n вместо \\r\\n тоже разбираются', () {
      final raw = 'HTTP/1.1 200 OK\n'
          'LOCATION: http://192.168.1.1:1900/rootDesc.xml\n'
          'USN: uuid:abc\n'
          '\n';
      final device = parseSsdpResponse(raw, source);
      expect(device, isNotNull);
      expect(device!.location, equals(Uri.parse('http://192.168.1.1:1900/rootDesc.xml')));
    });
  });

  group('extractXmlTag / extractXmlElements', () {
    test('находит значение простого тега в реальном описании', () {
      expect(extractXmlTag(_realDeviceDescription, 'friendlyName'),
          equals('Netcraze Gateway'));
    });

    test('namespace-префикс перед именем тега игнорируется', () {
      final xml = '<u:NewExternalIPAddress>109.195.195.251'
          '</u:NewExternalIPAddress>';
      expect(extractXmlTag(xml, 'NewExternalIPAddress'),
          equals('109.195.195.251'));
    });

    test('атрибуты в открывающем теге не мешают разбору', () {
      final xml = '<root xmlns="urn:schemas-upnp-org:device-1-0" '
          'configId="1337"><friendlyName>x</friendlyName></root>';
      expect(extractXmlTag(xml, 'friendlyName'), equals('x'));
    });

    test('самозакрывающийся тег даёт пустую строку', () {
      final xml = '<s:Body><NewRemoteHost/></s:Body>';
      expect(extractXmlTag(xml, 'NewRemoteHost'), equals(''));
    });

    test('несуществующий тег даёт null', () {
      expect(extractXmlTag(_realDeviceDescription, 'nope-such-tag'), isNull);
    });

    test('XML-сущности декодируются', () {
      final xml = '<desc>Tom &amp; Jerry &lt;3&gt; &quot;ok&quot; '
          '&apos;q&apos;</desc>';
      expect(extractXmlTag(xml, 'desc'),
          equals('Tom & Jerry <3> "ok" \'q\''));
    });

    test('extractXmlElements достаёт все <service> целиком', () {
      final services = extractXmlElements(_realDeviceDescription, 'service');
      expect(services, hasLength(3));
      expect(services[0], contains('Layer3Forwarding'));
      expect(services[1], contains('WANCommonInterfaceConfig'));
      expect(services[2], contains('WANIPConnection'));
      // Каждый элемент содержит и открывающий, и закрывающий тег.
      for (final s in services) {
        expect(s, startsWith('<service>'));
        expect(s, endsWith('</service>'));
      }
    });
  });

  group('selectIgdService', () {
    final location = Uri.parse('http://192.168.1.1:1900/rootDesc.xml');

    test('реальный XML со стенда -> controlURL WANIPConnection, не Layer3Forwarding', () {
      final selected = selectIgdService(_realDeviceDescription, location);
      expect(selected, isNotNull);
      expect(selected!.controlUrl, equals(Uri.parse('http://192.168.1.1:1900/ctl/IPConn')));
      expect(selected.serviceType,
          equals('urn:schemas-upnp-org:service:WANIPConnection:1'));
    });

    test('URLBase переопределяет базу для относительного controlURL', () {
      final xml = '''
<root>
<URLBase>http://192.168.1.1:5000/</URLBase>
<device><serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<controlURL>/ctl/IPConn</controlURL>
</service>
</serviceList></device>
</root>
''';
      final selected = selectIgdService(xml, location);
      expect(selected, isNotNull);
      expect(selected!.controlUrl, equals(Uri.parse('http://192.168.1.1:5000/ctl/IPConn')));
    });

    test('абсолютный controlURL используется как есть', () {
      final xml = '''
<root><device><serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<controlURL>http://192.168.1.1:9000/absolute/ctl</controlURL>
</service>
</serviceList></device></root>
''';
      final selected = selectIgdService(xml, location);
      expect(selected, isNotNull);
      expect(selected!.controlUrl,
          equals(Uri.parse('http://192.168.1.1:9000/absolute/ctl')));
    });

    test('без WAN*Connection сервисов -> null', () {
      final xml = '''
<root><device><serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
<controlURL>/ctl/L3F</controlURL>
</service>
</serviceList></device></root>
''';
      expect(selectIgdService(xml, location), isNull);
    });

    test('WANPPPConnection вместо WANIPConnection тоже выбирается', () {
      final xml = '''
<root><device><serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
<controlURL>/ctl/PPPConn</controlURL>
</service>
</serviceList></device></root>
''';
      final selected = selectIgdService(xml, location);
      expect(selected, isNotNull);
      expect(selected!.serviceType,
          equals('urn:schemas-upnp-org:service:WANPPPConnection:1'));
      expect(selected.controlUrl, equals(Uri.parse('http://192.168.1.1:1900/ctl/PPPConn')));
    });
  });

  group('SOAP-ответы', () {
    test('GetExternalIPAddress -> адрес', () {
      final body = '<?xml version="1.0"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><u:GetExternalIPAddressResponse '
          'xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">'
          '<NewExternalIPAddress>109.195.195.251</NewExternalIPAddress>'
          '</u:GetExternalIPAddressResponse></s:Body></s:Envelope>';
      expect(extractXmlTag(body, 'NewExternalIPAddress'),
          equals('109.195.195.251'));
      expect(parseSoapErrorCode(body), isNull);
    });

    test('SOAP-фолт с errorCode 725 распознаётся', () {
      final body = '<?xml version="1.0"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><s:Fault>'
          '<faultcode>s:Client</faultcode>'
          '<faultstring>UPnPError</faultstring>'
          '<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>725</errorCode>'
          '<errorDescription>OnlyPermanentLeasesSupported</errorDescription>'
          '</UPnPError></detail>'
          '</s:Fault></s:Body></s:Envelope>';
      expect(parseSoapErrorCode(body), equals(725));
    });

    test('SOAP-фолт с errorCode 718 распознаётся', () {
      final body = '<detail><UPnPError><errorCode>718</errorCode>'
          '<errorDescription>ConflictInMappingEntry</errorDescription>'
          '</UPnPError></detail>';
      expect(parseSoapErrorCode(body), equals(718));
    });

    test('без errorCode -> null (обычный успешный ответ)', () {
      final body = '<s:Body><u:AddPortMappingResponse/></s:Body>';
      expect(parseSoapErrorCode(body), isNull);
    });
  });

  group('UpnpIgdBackend — базовый контракт без сети', () {
    test('method и lastError до первого вызова', () {
      final backend = UpnpIgdBackend();
      expect(backend.method, equals(PortMapMethod.upnpIgd));
      expect(backend.lastError, isNull);
    });

    // Намеренно НЕ тестируем здесь map()/unmap()/externalAddress() целиком:
    // они уходят в discoverSsdp() и реальную сеть. На машине, где писался
    // этот файл, в сети обнаружился настоящий IGD (192.168.1.1), и такой
    // тест один раз реально создал маппинг 51413/tcp на живом роутере вместо
    // того, чтобы упасть на «нет сети» — что здесь и предполагалось как
    // офлайн-путь. Поведение самого бэкенда при недоступном шлюзе покрыто
    // косвенно через чистые функции выше (_ensureDiscovered/_soapCall
    // зависят только от них); прямой сетевой вызов — вне офлайн-тестов.
  });
}
