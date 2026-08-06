import 'dart:async';
import 'dart:io';

/// UPnP-мультикаст-группа SSDP (UPnP Device Architecture, фиксированный
/// адрес/порт для discovery).
const _ssdpMulticastAddress = '239.255.255.250';
const _ssdpPort = 1900;

/// Устройство, ответившее на SSDP M-SEARCH.
///
/// Значимый объект без поведения — как и [MappedPort] в `nat_backend.dart`,
/// держит только то, что нужно вызывающей стороне для GET по [location] и
/// для диагностики (откуда пришёл ответ, что это за устройство).
class SsdpDevice {
  /// Адрес XML-описания устройства (заголовок LOCATION).
  final Uri location;

  /// Заголовок SERVER — обычно строка вида `ОС/версия UPnP/1.1 ПО/версия`.
  final String? server;

  final String usn;

  /// Search target, на который пришёл этот ответ (заголовок ST).
  final String searchTarget;

  /// Адрес, с которого физически пришёл ответ — может отличаться от адреса
  /// в [location] (роутер отвечает с LAN-интерфейса, а LOCATION иногда
  /// содержит другой его же адрес).
  final InternetAddress sourceAddress;

  SsdpDevice({
    required this.location,
    required this.usn,
    required this.searchTarget,
    required this.sourceAddress,
    this.server,
  });

  @override
  String toString() => 'SsdpDevice($location, usn=$usn, st=$searchTarget, '
      'from=${sourceAddress.address})';
}

/// M-SEARCH по всем не-loopback IPv4 интерфейсам машины.
///
/// Отправляем с КАЖДОГО адреса отдельным сокетом, а не с `anyIPv4`: на
/// машине с docker-мостами (172.17.0.1, 172.18.0.1, ...) `anyIPv4` уходит
/// не в тот интерфейс, и домашний роутер на M-SEARCH просто не отвечает —
/// проверено живьём на стенде.
Future<List<SsdpDevice>> discoverSsdp({
  List<String> searchTargets = const [
    'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
    'urn:schemas-upnp-org:service:WANIPConnection:1',
    'urn:schemas-upnp-org:service:WANPPPConnection:1',
  ],
  Duration timeout = const Duration(seconds: 3),
}) async {
  final multicastTarget = InternetAddress(_ssdpMulticastAddress);
  final found = <SsdpDevice>[];
  final seen = <String>{}; // дедуп по паре (source, LOCATION)

  final sockets = <RawDatagramSocket>[];
  final subscriptions = <StreamSubscription>[];

  List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
  } catch (_) {
    // Платформа не даёт перечислить интерфейсы — discovery невозможен,
    // но это не повод падать наружу (контракт NatBackend не бросает).
    return found;
  }

  for (final iface in interfaces) {
    for (final address in iface.addresses) {
      RawDatagramSocket socket;
      try {
        socket = await RawDatagramSocket.bind(address, 0);
      } catch (_) {
        // bind не удался на этом адресе (интерфейс лёг, нет прав) —
        // остальные адреса всё равно пробуем.
        continue;
      }

      try {
        // Аналог IP_MULTICAST_TTL: часть роутеров сидит не на первом хопе
        // от адреса интерфейса (виртуалки, VPN-мосты), и TTL=1 по умолчанию
        // ответ бы обрезал.
        socket.multicastHops = 4;
      } catch (_) {
        // Не все платформы позволяют менять TTL на уже забинженном сокете —
        // не критично, шлём с дефолтным.
      }

      sockets.add(socket);
      subscriptions.add(socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        try {
          final raw = String.fromCharCodes(datagram.data);
          final device = parseSsdpResponse(raw, datagram.address);
          if (device == null) return;
          final key = '${device.sourceAddress.address}|${device.location}';
          if (seen.add(key)) found.add(device);
        } catch (_) {
          // Битый/неожиданный ответ — игнорируем, остальные не теряем.
        }
      }, onError: (_) {}));

      for (final searchTarget in searchTargets) {
        final message = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: $_ssdpMulticastAddress:$_ssdpPort\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $searchTarget\r\n'
            '\r\n';
        try {
          socket.send(message.codeUnits, multicastTarget, _ssdpPort);
        } catch (_) {
          // Отправка не удалась (нет мультикаста на интерфейсе, EPERM) —
          // остальные ST/сокеты не трогаем.
        }
      }
    }
  }

  await Future.delayed(timeout);

  for (final sub in subscriptions) {
    await sub.cancel();
  }
  for (final socket in sockets) {
    socket.close();
  }

  return found;
}

/// Разбор одного HTTP-ответа SSDP в [SsdpDevice]. Публичная — тестируется
/// без сети на реальных фикстурах ответов.
///
/// `null`, если это не `200 OK` или нет валидного LOCATION.
SsdpDevice? parseSsdpResponse(String raw, InternetAddress source) {
  // Реальные роутеры шлют \r\n, но толерантность к голому \n дешева и
  // подстраховывает от прокси/тестовых генераторов ответов.
  final lines = raw.split(RegExp(r'\r\n|\n'));
  if (lines.isEmpty) return null;

  final statusMatch =
      RegExp(r'^HTTP/\d\.\d\s+(\d{3})').firstMatch(lines.first.trim());
  if (statusMatch == null || statusMatch.group(1) != '200') return null;

  final headers = <String, String>{};
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    // Заголовки регистронезависимы: реальные роутеры шлют LOCATION,
    // Location, location вперемешку — покрыто: test/upnp_igd_test.dart.
    final name = line.substring(0, colon).trim().toUpperCase();
    final value = line.substring(colon + 1).trim();
    headers[name] = value;
  }

  final locationRaw = headers['LOCATION'];
  if (locationRaw == null || locationRaw.isEmpty) return null;
  final location = Uri.tryParse(locationRaw);
  if (location == null || !location.hasScheme) return null;

  return SsdpDevice(
    location: location,
    server: headers['SERVER'],
    usn: headers['USN'] ?? '',
    searchTarget: headers['ST'] ?? '',
    sourceAddress: source,
  );
}
