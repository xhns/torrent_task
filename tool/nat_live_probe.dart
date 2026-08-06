// ВРЕМЕННЫЙ стенд живой проверки NAT-проброса. Удаляется после прогона.
import 'dart:async';
import 'dart:io';
import 'package:torrent_task/src/nat/port_mapper.dart';
import 'package:torrent_task/src/nat/upnp_igd.dart';
import 'package:torrent_task/src/nat/nat_pmp.dart';
import 'package:torrent_task/src/nat/pcp.dart';
import 'package:torrent_task/src/nat/gateway.dart';

void log(String m) => print('[${DateTime.now().toIso8601String().substring(11, 19)}] $m');

Future<void> probeBackend(String name, dynamic backend, int port) async {
  final sw = Stopwatch()..start();
  try {
    final ext = await backend.externalAddress();
    final tcp = await backend.map(
        internalPort: port, protocol: PortProtocol.tcp, lease: const Duration(seconds: 900));
    final udp = await backend.map(
        internalPort: port, protocol: PortProtocol.udp, lease: const Duration(seconds: 900));
    log('$name: extAddr=${ext?.address}  tcp=$tcp  udp=$udp  err=${backend.lastError}  (${sw.elapsedMilliseconds}ms)');
    if (tcp != null) {
      final ok = await backend.unmap(tcp);
      log('$name: unmap tcp -> $ok');
    }
    if (udp != null) {
      final ok = await backend.unmap(udp);
      log('$name: unmap udp -> $ok');
    }
  } catch (e) {
    log('$name: УПАЛ: $e');
  }
  await backend.dispose();
}

void main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 51413;
  log('кандидаты в шлюзы: ${(await discoverGatewayCandidates()).map((a) => a.address).toList()}');

  await probeBackend('UPnP  ', UpnpIgdBackend(description: 'torrent_task probe'), port);
  await probeBackend('NAT-PMP', NatPmpBackend(), port);
  await probeBackend('PCP   ', PcpBackend(), port);

  log('--- фасад PortMapper (порядок по умолчанию) ---');
  final mapper = PortMapper(description: 'torrent_task');
  final result = await mapper.map(internalPort: port, lease: const Duration(seconds: 900));
  log('map -> $result');
  log('status -> ${mapper.status}');
  final s = mapper.status;
  if (s.externalAddress != null) {
    log('ВНЕШНЯЯ ТОЧКА: ${s.externalAddress!.address}  tcp=${s.externalTcpPort}  udp=${s.externalUdpPort}');
  }
  // Держим маппинг и слушаем оба транспорта, чтобы проверить снаружи.
  final tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  var tcpHits = 0;
  tcpServer.listen((sock) {
    tcpHits++;
    log('*** ВХОДЯЩЕЕ TCP от ${sock.remoteAddress.address}:${sock.remotePort} (всего $tcpHits)');
    sock.write('NAT-PROBE-OK\n');
    sock.close();
  });
  final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: false);
  var udpHits = 0;
  udpSocket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final dg = udpSocket.receive();
    if (dg == null) return;
    udpHits++;
    log('*** ВХОДЯЩАЯ UDP-датаграмма от ${dg.address.address}:${dg.port}, ${dg.data.length} байт (всего $udpHits)');
  });
  log('слушаю TCP+UDP $port; жду 100 секунд');
  await Future.delayed(const Duration(seconds: 100));
  log('ИТОГ: tcpHits=$tcpHits udpHits=$udpHits');
  await tcpServer.close();
  udpSocket.close();
  await mapper.dispose();
  log('маппинг снят, статус: ${mapper.status}');
  exit(0);
}
