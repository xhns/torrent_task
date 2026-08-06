import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'nat_backend.dart';
import 'ssdp.dart';

/// Бэкенд пробивания NAT через UPnP Internet Gateway Device: SSDP discovery
/// + SOAP `AddPortMapping`/`DeletePortMapping`/`GetExternalIPAddress` на
/// сервисе `WANIPConnection`/`WANPPPConnection`.
class UpnpIgdBackend implements NatBackend {
  UpnpIgdBackend({
    this.description = 'torrent_task',
    this.timeout = const Duration(seconds: 5),
  }) : _http = HttpClient() {
    _http.connectionTimeout = timeout;
    // На этой машине бывает корпоративный прокси в окружении, через
    // который до роутера в LAN (192.168.x.x) не достучаться — discovery/SOAP
    // обязаны идти напрямую.
    _http.findProxy = (_) => 'DIRECT';
  }

  /// Текст в `NewPortMappingDescription` — то, что часть прошивок показывает
  /// в списке проброшенных портов в веб-морде роутера.
  final String description;

  final Duration timeout;
  final HttpClient _http;

  @override
  final PortMapMethod method = PortMapMethod.upnpIgd;

  String? _lastError;
  @override
  String? get lastError => _lastError;

  // Результат discovery кэшируется здесь: повторный map()/unmap() не гоняет
  // SSDP+GET описания заново, пока controlUrl уже есть.
  Uri? _controlUrl;
  String? _serviceType;

  /// Ленивый discovery: SSDP → GET описания устройства → выбор WAN-сервиса.
  /// Успех кэшируется в [_controlUrl]/[_serviceType]; неудача — нет (шлюз
  /// мог просто ещё не подняться), следующий вызов пробует снова.
  Future<bool> _ensureDiscovered() async {
    if (_controlUrl != null) return true;
    try {
      final devices = await discoverSsdp(timeout: timeout);
      if (devices.isEmpty) {
        _lastError = 'SSDP не нашёл ни одного UPnP-устройства';
        return false;
      }
      for (final device in devices) {
        final xml = await _httpGet(device.location);
        if (xml == null) continue;
        final selected = selectIgdService(xml, device.location);
        if (selected == null) continue;
        _controlUrl = selected.controlUrl;
        _serviceType = selected.serviceType;
        _lastError = null;
        return true;
      }
      _lastError = 'Ни одно из найденных SSDP-устройств не отдало '
          'WANIPConnection/WANPPPConnection';
      return false;
    } catch (e) {
      _lastError = 'SSDP discovery упал: $e';
      return false;
    }
  }

  Future<String?> _httpGet(Uri url) async {
    try {
      final request = await _http.getUrl(url).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      return await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// SOAP-запрос к `_controlUrl`. Возвращает `(http-статус, тело)` —
  /// SOAP-фолт (errorCode) приходит с HTTP 500, но тело нужно разобрать
  /// в обоих случаях, поэтому статус и тело возвращаются вместе, а не
  /// схлопываются в null при не-200.
  Future<(int, String)?> _soapCall(
      String action, Map<String, String> args) async {
    final controlUrl = _controlUrl;
    final serviceType = _serviceType;
    if (controlUrl == null || serviceType == null) return null;

    final body = StringBuffer()
      ..write('<?xml version="1.0"?>')
      ..write('<s:Envelope '
          'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
      ..write('<s:Body><u:$action xmlns:u="$serviceType">');
    args.forEach((key, value) {
      body.write('<$key>${_escapeXml(value)}</$key>');
    });
    body.write('</u:$action></s:Body></s:Envelope>');

    try {
      final request = await _http.postUrl(controlUrl).timeout(timeout);
      final bytes = utf8.encode(body.toString());
      // Часть встроенных HTTP-серверов IGD (в т.ч. miniupnpd) не умеет
      // chunked-запросы — без явного Content-Length Dart шлёт chunked по
      // умолчанию для request.write(), и POST на реальном роутере повисал.
      request.headers.contentLength = bytes.length;
      request.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      request.headers.set('SOAPAction', '"$serviceType#$action"');
      request.add(bytes);
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      return (response.statusCode, text);
    } catch (e) {
      _lastError = 'SOAP $action не удался: $e';
      return null;
    }
  }

  @override
  Future<InternetAddress?> externalAddress() async {
    if (!await _ensureDiscovered()) return null;
    final result = await _soapCall('GetExternalIPAddress', const {});
    if (result == null) return null;
    final (_, response) = result;

    final errorCode = parseSoapErrorCode(response);
    if (errorCode != null) {
      _lastError = 'GetExternalIPAddress вернул SOAP-фолт $errorCode';
      return null;
    }

    final ipStr = extractXmlTag(response, 'NewExternalIPAddress');
    if (ipStr == null || ipStr.isEmpty || ipStr == '0.0.0.0') {
      _lastError = 'GetExternalIPAddress не вернул валидный адрес';
      return null;
    }
    final addr = InternetAddress.tryParse(ipStr);
    if (addr == null) {
      _lastError = 'GetExternalIPAddress вернул нераспознаваемый адрес: $ipStr';
      return null;
    }
    _lastError = null;
    return addr;
  }

  /// LAN-адрес нашей машины, который надо подставить в `NewInternalClient`.
  ///
  /// Берём адрес интерфейса, чьи первые три октета совпадают с хостом
  /// [_controlUrl] (значит, интерфейс смотрит в ту же подсеть, что и
  /// шлюз); если совпадения нет — первый не-loopback IPv4 как разумный
  /// дефолт (одна активная сеть — обычный случай для десктопа/сервера).
  Future<String?> _pickInternalClient() async {
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
    } catch (_) {
      return null;
    }
    final all = <String>[
      for (final iface in interfaces)
        for (final addr in iface.addresses) addr.address,
    ];
    if (all.isEmpty) return null;

    final controlHost = _controlUrl?.host;
    final prefix = controlHost == null ? null : _threeOctetPrefix(controlHost);
    if (prefix != null) {
      for (final address in all) {
        if (address.startsWith(prefix)) return address;
      }
    }
    return all.first;
  }

  static String? _threeOctetPrefix(String ipv4) {
    final parts = ipv4.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.';
  }

  @override
  Future<MappedPort?> map({
    required int internalPort,
    required PortProtocol protocol,
    required Duration lease,
    int? suggestedExternalPort,
  }) async {
    if (!await _ensureDiscovered()) return null;

    final internalClient = await _pickInternalClient();
    if (internalClient == null) {
      _lastError = 'Не нашли LAN-адрес для NewInternalClient';
      return null;
    }

    var externalPort = suggestedExternalPort ?? internalPort;
    var requestedLease = lease;
    var conflictRetries = 0;

    while (true) {
      // Порядок ключей значим для части IGD (парсят SOAP-тело позиционно,
      // а не как настоящий XML) — не переставлять без причины.
      final args = <String, String>{
        'NewRemoteHost': '',
        'NewExternalPort': '$externalPort',
        'NewProtocol': protocol.upnpName,
        'NewInternalPort': '$internalPort',
        'NewInternalClient': internalClient,
        'NewEnabled': '1',
        'NewPortMappingDescription': description,
        'NewLeaseDuration': '${requestedLease.inSeconds}',
      };

      final result = await _soapCall('AddPortMapping', args);
      if (result == null) return null; // _lastError уже выставлен внутри
      final (_, response) = result;

      final errorCode = parseSoapErrorCode(response);
      if (errorCode == null) {
        _lastError = null;
        return MappedPort(
          method: PortMapMethod.upnpIgd,
          protocol: protocol,
          internalPort: internalPort,
          // AddPortMapping не возвращает выданный порт — внешним считается
          // тот, что мы запросили и который шлюз принял без ошибки.
          externalPort: externalPort,
          externalAddress: await externalAddress(),
          lifetime: requestedLease,
          createdAt: DateTime.now(),
        );
      }

      if (errorCode == 725 && requestedLease != Duration.zero) {
        // OnlyPermanentLeasesSupported: часть прошивок не умеет ограниченную
        // аренду и требует бессрочную — повторяем один раз с lease=0.
        requestedLease = Duration.zero;
        continue;
      }

      if (errorCode == 718 && conflictRetries < 3) {
        // ConflictInMappingEntry: запрошенный внешний порт уже занят другим
        // маппингом — пробуем соседние порты, как это делают реальные
        // клиенты (transmission, qBittorrent).
        conflictRetries++;
        externalPort = internalPort + conflictRetries;
        continue;
      }

      _lastError = 'AddPortMapping отказал: код $errorCode';
      return null;
    }
  }

  @override
  Future<bool> unmap(MappedPort mapping) async {
    if (!await _ensureDiscovered()) return false;

    final args = <String, String>{
      'NewRemoteHost': '',
      'NewExternalPort': '${mapping.externalPort}',
      'NewProtocol': mapping.protocol.upnpName,
    };
    final result = await _soapCall('DeletePortMapping', args);
    if (result == null) return false;
    final (status, response) = result;

    final errorCode = parseSoapErrorCode(response);
    if (status != 200 || errorCode != null) {
      _lastError = 'DeletePortMapping отказал: '
          'http=$status${errorCode != null ? ', код $errorCode' : ''}';
      return false;
    }
    _lastError = null;
    return true;
  }

  @override
  Future<void> dispose() async {
    _http.close(force: true);
    _controlUrl = null;
    _serviceType = null;
  }
}

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Выбор WAN-сервиса (`WANIPConnection`/`WANPPPConnection`) из device
/// description по SSDP LOCATION.
///
/// Наивный «первый `<controlURL>` в файле» ловит `Layer3Forwarding` вместо
/// нужного WAN-сервиса — реальные описания складывают его раньше в дереве.
/// Покрыто: test/upnp_igd_test.dart.
({Uri controlUrl, String serviceType})? selectIgdService(
    String descriptionXml, Uri location) {
  // <URLBase>, если есть, переопределяет базу для относительных
  // controlURL — часть прошивок отдаёт панель управления на другом порту,
  // чем rootDesc.xml.
  final urlBaseStr = extractXmlTag(descriptionXml, 'URLBase');
  final base = (urlBaseStr != null && urlBaseStr.isNotEmpty)
      ? (Uri.tryParse(urlBaseStr) ?? location)
      : location;

  for (final serviceXml in extractXmlElements(descriptionXml, 'service')) {
    final serviceType = extractXmlTag(serviceXml, 'serviceType');
    if (serviceType == null) continue;
    final isWanConnection = serviceType
            .startsWith('urn:schemas-upnp-org:service:WANIPConnection:') ||
        serviceType
            .startsWith('urn:schemas-upnp-org:service:WANPPPConnection:');
    if (!isWanConnection) continue;

    final controlUrlStr = extractXmlTag(serviceXml, 'controlURL');
    if (controlUrlStr == null || controlUrlStr.isEmpty) continue;

    return (controlUrl: base.resolve(controlUrlStr), serviceType: serviceType);
  }
  return null;
}

/// SOAP-фолт `<errorCode>` (UPnP `errorDescription`/`UPnPError`), либо
/// `null` при обычном успешном ответе.
///
/// Покрыто: test/upnp_igd_test.dart.
int? parseSoapErrorCode(String soapBody) {
  final code = extractXmlTag(soapBody, 'errorCode');
  if (code == null) return null;
  return int.tryParse(code.trim());
}

/// Значение первого тега [tag] (без учёта namespace-префикса) в [xml],
/// либо `null`, если тег не найден.
///
/// Толерантен к атрибутам в открывающем теге, самозакрывающимся тегам
/// (→ пустая строка) и базовым XML-сущностям. Специально не тянем пакет
/// `xml` в зависимости — под наши нужды (плоские значения полей SOAP/device
/// description) регулярки достаточно.
/// Покрыто: test/upnp_igd_test.dart.
String? extractXmlTag(String xml, String tag) {
  final match = _elementPattern(tag).firstMatch(xml);
  if (match == null) return null;
  final inner = match.group(1); // null у самозакрывающегося тега
  if (inner == null) return '';
  return _decodeXmlEntities(inner.trim());
}

/// Все вхождения элемента [tag] целиком (открывающий тег + содержимое +
/// закрывающий, либо самозакрывающийся тег) — для перебора повторяющихся
/// узлов вроде `<service>`.
/// Покрыто: test/upnp_igd_test.dart.
List<String> extractXmlElements(String xml, String tag) {
  return _elementPattern(tag)
      .allMatches(xml)
      .map((m) => m.group(0)!)
      .toList();
}

RegExp _elementPattern(String tag) {
  final escaped = RegExp.escape(tag);
  // Необязательный namespace-префикс (`u:`, `s:`, ...) перед именем тега —
  // одно и то же поле в SOAP-ответе встречается то с префиксом, то без.
  // dotAll, чтобы значение могло переноситься строкой (pretty-printed XML).
  return RegExp(
    '<(?:[\\w.-]+:)?$escaped(?:\\s[^>]*)?(?:/>|>(.*?)</(?:[\\w.-]+:)?$escaped\\s*>)',
    dotAll: true,
    caseSensitive: false,
  );
}

String _decodeXmlEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    // &amp; декодируем последним, иначе «&amp;lt;» (уже заэкранированный
    // «&lt;» в исходных данных) превратился бы в «<» вместо «&lt;».
    .replaceAll('&amp;', '&');
