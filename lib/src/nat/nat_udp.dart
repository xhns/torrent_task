import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Ответ шлюза на запрос NAT-PMP/PCP.
class GatewayReply {
  final InternetAddress gateway;
  final Uint8List data;

  GatewayReply(this.gateway, this.data);
}

/// Одна UDP-транзакция «запрос → ответ» к шлюзу, общая для NAT-PMP и PCP.
///
/// Оба протокола живут на одном порту (5351), одинаково не гарантируют
/// доставку и одинаково требуют игнорировать пакеты, пришедшие не от того,
/// кого спрашивали (RFC 6886 §3.1, RFC 6887 §8.1) — иначе любой сосед по LAN
/// может подсунуть нам «внешний адрес».
///
/// Кандидатов в шлюзы несколько (см. `gateway.dart`), и опрашиваются они
/// ОДНОВРЕМЕННО: последовательный перебор с таймаутом на каждого добавлял бы
/// секунды к старту задачи ради адресов, которые чаще всего просто молчат.
class NatUdpTransaction {
  static const int defaultServerPort = 5351;

  final int serverPort;

  NatUdpTransaction({this.serverPort = defaultServerPort});

  /// Разослать [payload] всем [gateways] и вернуть первый ответ, принятый
  /// предикатом [accept], либо `null` по истечении времени.
  ///
  /// [retryDelays] — паузы между повторами (RFC 6886 предписывает начинать с
  /// 250 мс и удваивать). Число повторов равно длине списка.
  Future<GatewayReply?> request({
    required List<InternetAddress> gateways,
    required Uint8List payload,
    required bool Function(InternetAddress gateway, Uint8List data) accept,
    List<Duration> retryDelays = const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
      Duration(milliseconds: 1000),
    ],
  }) async {
    if (gateways.isEmpty) return null;
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      return null;
    }
    final completer = Completer<GatewayReply?>();
    final expected = {for (var g in gateways) g.address};
    StreamSubscription? sub;
    Timer? deadline;

    void finish(GatewayReply? reply) {
      if (completer.isCompleted) return;
      deadline?.cancel();
      sub?.cancel();
      socket?.close();
      completer.complete(reply);
    }

    sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket?.receive();
      if (dg == null) return;
      if (dg.port != serverPort) return;
      if (!expected.contains(dg.address.address)) return;
      final data = Uint8List.fromList(dg.data);
      if (!accept(dg.address, data)) return;
      finish(GatewayReply(dg.address, data));
    }, onError: (e) => finish(null), onDone: () => finish(null));

    void send() {
      for (var g in gateways) {
        try {
          socket?.send(payload, g, serverPort);
        } catch (e) {
          // Недостижимый кандидат (нет маршрута) — остальные не виноваты.
        }
      }
    }

    send();
    var total = Duration.zero;
    for (var delay in retryDelays) {
      total += delay;
      Timer(total, () {
        if (completer.isCompleted) return;
        send();
      });
    }
    // Последнему повтору тоже нужно время на ответ.
    deadline = Timer(total + const Duration(milliseconds: 700), () {
      finish(null);
    });

    return completer.future;
  }
}
