import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:dartorrent_common/dartorrent_common.dart';

// const LSD_HOST = '239.192.152.143';
// const LSD_PORT = 6771;

class LSD {
  static const String LSD_HOST_ADDRESS = '239.192.152.143';

  static final InternetAddress LSD_HOST =
      InternetAddress.fromRawAddress(Uint8List.fromList([239, 192, 152, 143]));
  static const int LSD_PORT = 6771;

  static final String ANNOUNCE_FIREST_LINE = 'BT-SEARCH * HTTP/1.1\r\n';

  bool _closed = false;

  bool get isClosed => _closed;

  RawDatagramSocket? _socket;

  final String? _infoHashHex;

  int? port;

  final String? _peerId;

  final Set<Function(CompactAddress address, String infoHashHex)>
      _peerHandlers = <Function(CompactAddress, String)>{};

  /// Порт группы LSD. По умолчанию — стандартный 6771; переопределяется в
  /// тестах, чтобы не драться за общесистемный порт с соседними прогонами.
  final int groupPort;

  LSD(this._infoHashHex, this._peerId, {this.groupPort = LSD_PORT});

  Timer? _timer;

  void start() async {
    _socket ??= await _bind();
    // Без вступления в мультикаст-группу сокет на 0.0.0.0:6771 не получает
    // групповой трафик вообще: LSD-анонсы соседей до нас просто не доходили,
    // и обработчик пиров не вызывался ни разу.
    // Покрыто: test/lsd_peer_test.dart.
    try {
      _socket!.joinMulticast(LSD_HOST);
    } catch (e) {
      // Интерфейс без мультикаста — LSD не работает, остальные способы
      // обнаружения (трекер, DHT, PEX) не затронуты.
    }
    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        var datagram = _socket!.receive();
        var datas = datagram!.data;
        var str = String.fromCharCodes(datas);
        _processReceive(str, datagram.address);
      }
    }, onDone: () {}, onError: (e) {});
    await _announce();
  }

  /// 6771 обязан быть разделяемым: в одном процессе живёт по [LSD] на каждую
  /// задачу, и без `reusePort` вторая книга падала бы на bind. `reusePort`
  /// поддержан не везде (Windows), поэтому есть откат.
  Future<RawDatagramSocket> _bind() async {
    try {
      return await RawDatagramSocket.bind(InternetAddress.anyIPv4, groupPort,
          reuseAddress: true, reusePort: true);
    } catch (e) {
      return await RawDatagramSocket.bind(InternetAddress.anyIPv4, groupPort,
          reuseAddress: true);
    }
  }

  bool onLSDPeer(void Function(CompactAddress address, String infoHashHex) h) {
    return _peerHandlers.add(h);
  }

  bool offLSDPeer(void Function(CompactAddress address, String infoHashHex) h) {
    return _peerHandlers.remove(h);
  }

  void _fireLSDPeerEvent(InternetAddress address, int port, String infoHash) {
    var add = CompactAddress(address, port);
    for (var element in _peerHandlers) {
      Timer.run(() => element(add, infoHash));
    }
  }

  void _processReceive(String str, InternetAddress source) {
    var strs = str.split('\r\n');
    // `split('\r\n')` уже съел разделитель, а ANNOUNCE_FIREST_LINE его
    // содержит: сравнение «в лоб» не совпадало НИКОГДА, и любой LSD-анонс
    // отбрасывался ещё до разбора полей.
    // Покрыто: test/lsd_peer_test.dart.
    if (strs[0] != ANNOUNCE_FIREST_LINE.trimRight()) return;
    int? port;
    String? infoHash;
    String? cookie;
    for (var i = 1; i < strs.length; i++) {
      var element = strs[i];
      if (element.startsWith('Port:')) {
        var index = element.indexOf('Port:');
        index += 5;
        var portStr = element.substring(index);
        port = int.tryParse(portStr.trim());
      }
      if (element.startsWith('Infohash:')) {
        // После двоеточия идёт пробел (так пишут и клиенты, и мы сами) — без
        // trim в infoHash попадал 41 символ и проверка длины 40 не проходила
        // никогда, то есть анонс отбрасывался даже после успешного разбора.
        // Покрыто: test/lsd_peer_test.dart.
        infoHash = element.substring(9).trim();
      }
      // BEP 14: cookie нужен ровно для того, чтобы отличить собственный анонс.
      // Мы шлём на мультикаст-группу, в которой сами же и состоим, поэтому свой
      // же BT-SEARCH приходит обратно; без этой проверки клиент добавлял бы
      // сам себя как пира и ходил на собственный слушающий порт.
      // Покрыто: test/lsd_peer_test.dart.
      if (element.toLowerCase().startsWith('cookie:')) {
        cookie = element.substring(7).trim();
      }
    }
    if (cookie != null && cookie == _ownCookie) return;

    if (port != null && infoHash != null) {
      // BUGFIX: upper bound was 63354 (a typo); the maximum TCP/UDP port is
      // 65535, so announces on ports 63355-65535 were silently dropped.
      if (port >= 0 && port <= 65535 && infoHash.length == 40) {
        _fireLSDPeerEvent(source, port, infoHash);
      }
    }
  }

  Future _announce() async {
    _timer?.cancel();
    var message = _createMessage();
    await _sendMessage(message);
    _timer = Timer(Duration(seconds: 5 * 60), () => _announce());
  }

  Future? _sendMessage(String message, [Completer? completer]) {
    if (_socket == null) return null;
    completer ??= Completer();
    var success = _socket!.send(message.codeUnits, LSD_HOST, groupPort) > 0;
    if (!success) {
      Timer.run(() => _sendMessage(message, completer));
    } else {
      completer.complete();
    }
    return completer.future;
  }

  /// BT-SEARCH * HTTP/1.1\r\n
  ///
  ///Host: <host>\r\n
  ///
  ///Port: <port>\r\n
  ///
  ///Infohash: <ihash>\r\n
  ///
  ///cookie: <cookie (optional)>\r\n
  ///
  ///\r\n
  ///
  ///\r\n
  String _createMessage() {
    return '${ANNOUNCE_FIREST_LINE}Host: $LSD_HOST_ADDRESS:$groupPort\r\n'
        'Port: $port\r\nInfohash: $_infoHashHex\r\ncookie: $_ownCookie\r\n\r\n\r\n';
  }

  /// Наш собственный BEP 14 cookie — им же помечены исходящие анонсы, по нему
  /// же они отсеиваются на приёме.
  String get _ownCookie => 'dt-client$_peerId';

  void close() {
    if (isClosed) return;
    _closed = true;
    _socket?.close();
    _timer?.cancel();
    _peerHandlers.clear();
  }
}
