import 'dart:io';
import 'dart:typed_data';

/// Поиск адреса NAT-шлюза для NAT-PMP/PCP.
///
/// «Шлюз по умолчанию из таблицы маршрутизации» — не синоним «устройства, где
/// живёт NAT». На домашнем стенде разработчика default route ведёт на
/// 192.168.1.51 (транзитная коробка), а NAT и NAT-PMP/PCP-сервер — на
/// 192.168.1.1: запрос строго на default gateway не получал ответа вообще.
/// Поэтому кандидатов несколько и опрашиваются они параллельно.
/// Покрыто: test/nat_gateway_test.dart.

/// Кандидаты в адреса NAT-шлюза, в порядке убывания правдоподобия.
///
/// [extraCandidates] — адреса, полученные другим путём (например хост IGD,
/// найденного по SSDP): такой адрес почти наверняка и есть NAT.
Future<List<InternetAddress>> discoverGatewayCandidates({
  Iterable<InternetAddress> extraCandidates = const [],
}) async {
  final result = <String, InternetAddress>{};

  void add(InternetAddress? a) {
    if (a == null) return;
    if (!isUsableGatewayAddress(a)) return;
    result.putIfAbsent(a.address, () => a);
  }

  for (var a in extraCandidates) {
    add(a);
  }

  for (var a in await _routingTableGateways()) {
    add(a);
  }

  final locals = await localIPv4Addresses();
  for (var a in subnetGatewayGuesses(locals)) {
    add(a);
  }

  return result.values.toList(growable: false);
}

/// Годится ли адрес в качестве шлюза: не loopback, не «любой», не
/// link-local (169.254/16 — признак того, что DHCP не отработал), не мультикаст.
bool isUsableGatewayAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final raw = address.rawAddress;
  if (raw.length != 4) return false;
  if (raw[0] == 0) return false;
  if (raw[0] == 127) return false;
  if (raw[0] == 169 && raw[1] == 254) return false;
  if (raw[0] >= 224) return false;
  return true;
}

/// Не-loopback IPv4 адреса этой машины.
Future<List<InternetAddress>> localIPv4Addresses() async {
  try {
    final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    return [
      for (var i in ifaces)
        for (var a in i.addresses)
          if (!a.isLoopback) a
    ];
  } catch (e) {
    return const [];
  }
}

/// Классическая догадка «шлюз — это .1 в моей /24».
///
/// Именно она спасает там, где таблица маршрутизации указывает мимо NAT'а.
/// Маску мы не знаем (Dart её не отдаёт), поэтому предполагаем /24 — для
/// домашних сетей это верно практически всегда.
List<InternetAddress> subnetGatewayGuesses(Iterable<InternetAddress> locals) {
  final out = <String, InternetAddress>{};
  for (var a in locals) {
    final raw = a.rawAddress;
    if (raw.length != 4) continue;
    if (raw[3] == 1) continue; // мы сами и есть .1 — шлюзом себе не будем
    final guess = InternetAddress.fromRawAddress(
        Uint8List.fromList([raw[0], raw[1], raw[2], 1]));
    if (!isUsableGatewayAddress(guess)) continue;
    out.putIfAbsent(guess.address, () => guess);
  }
  return out.values.toList(growable: false);
}

/// Локальный адрес, с которого мы, скорее всего, разговариваем с [target].
///
/// Нужен для PCP (клиент обязан указать свой IP в запросе) и для UPnP
/// (`NewInternalClient`). Выбираем по самому длинному совпадению префикса —
/// на машине с десятком docker-мостов «первый попавшийся» промахивается.
Future<InternetAddress?> localAddressFor(InternetAddress target) async {
  final locals = await localIPv4Addresses();
  return pickLocalAddressFor(target, locals);
}

/// Чистое ядро [localAddressFor] — вынесено ради тестов.
/// Покрыто: test/nat_gateway_test.dart.
InternetAddress? pickLocalAddressFor(
    InternetAddress target, Iterable<InternetAddress> locals) {
  final t = target.rawAddress;
  if (t.length != 4) return locals.isEmpty ? null : locals.first;
  InternetAddress? best;
  var bestScore = -1;
  for (var a in locals) {
    final r = a.rawAddress;
    if (r.length != 4) continue;
    var score = 0;
    for (var i = 0; i < 4; i++) {
      if (r[i] != t[i]) break;
      score++;
    }
    if (score > bestScore) {
      bestScore = score;
      best = a;
    }
  }
  return best;
}

Future<List<InternetAddress>> _routingTableGateways() async {
  if (Platform.isLinux || Platform.isAndroid) {
    try {
      final content = await File('/proc/net/route').readAsString();
      return parseProcNetRoute(content);
    } catch (e) {
      return const [];
    }
  }
  if (Platform.isMacOS) {
    try {
      final r = await Process.run('route', ['-n', 'get', 'default']);
      final gw = parseRouteGetDefault('${r.stdout}');
      return gw == null ? const [] : [gw];
    } catch (e) {
      return const [];
    }
  }
  // Windows и всё прочее: остаёмся на догадке `.1` из [subnetGatewayGuesses].
  // Process-разбор `route print`/`Get-NetRoute` тут заведомо хрупче, чем эта
  // догадка, а UPnP (SSDP) на Windows работает и без знания шлюза.
  return const [];
}

/// Разбор `/proc/net/route`: адреса шлюзов маршрутов по умолчанию.
///
/// Формат — табулированный текст с шапкой; адреса записаны как 32-битное
/// little-endian значение в hex, то есть `3301A8C0` — это 192.168.1.51,
/// а не 51.1.168.192.
/// Покрыто: test/nat_gateway_test.dart.
List<InternetAddress> parseProcNetRoute(String content) {
  final out = <String, InternetAddress>{};
  final lines = content.split('\n');
  for (var i = 1; i < lines.length; i++) {
    final parts = lines[i].trim().split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final dest = int.tryParse(parts[1], radix: 16);
    final gw = int.tryParse(parts[2], radix: 16);
    if (dest == null || gw == null) continue;
    if (dest != 0) continue; // не маршрут по умолчанию
    if (gw == 0) continue; // on-link default: шлюза как узла нет
    final addr = _fromLittleEndianHex(gw);
    if (!isUsableGatewayAddress(addr)) continue;
    out.putIfAbsent(addr.address, () => addr);
  }
  return out.values.toList(growable: false);
}

InternetAddress _fromLittleEndianHex(int value) {
  return InternetAddress.fromRawAddress(Uint8List.fromList([
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]));
}

/// Разбор вывода `route -n get default` (macOS/BSD).
/// Покрыто: test/nat_gateway_test.dart.
InternetAddress? parseRouteGetDefault(String output) {
  for (var line in output.split('\n')) {
    final t = line.trim();
    if (!t.toLowerCase().startsWith('gateway:')) continue;
    final value = t.substring(8).trim();
    try {
      final a = InternetAddress(value);
      if (isUsableGatewayAddress(a)) return a;
    } catch (e) {
      return null;
    }
  }
  return null;
}
