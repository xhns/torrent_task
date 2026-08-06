import 'dart:async';
import 'dart:math';

import '../utils.dart';

/// 500 ms
const CCONTROL_TARGET = 1000000;

const MAX_WINDOW = 1048576;

const RECORD_TIME = 5000000;

/// 最大每次增加的request为3
const MAX_CWND_INCREASE_REQUESTS_PER_RTT = 3 * 16384;

/// LEDBAT拥塞控制
///
/// 注意，所有时间单位都是微秒
mixin CongestionControl {
  // 初始是10秒
  double _rto = 10000000;

  double? _srtt;

  double? _rttvar;

  Timer? _timeout;

  int _allowWindowSize = DEFAULT_REQUEST_LENGTH;

  final List<List<dynamic>> _downloadedHistory = <List<dynamic>>[];

  final Set<void Function(dynamic source, List<List<int>> requests)> _handles =
      <void Function(dynamic source, List<List<int>> requests)>{};

  /// Add `request timeout` event handler
  bool onRequestTimeout(
      void Function(dynamic source, List<List<int>> requests) handle) {
    return _handles.add(handle);
  }

  /// Remove `request timeout` event handler
  bool offRequestTimeout(
      void Function(dynamic source, List<List<int>> requests) handle) {
    return _handles.remove(handle);
  }

  /// 更新超时时间
  void updateRTO(int rtt) {
    if (rtt == 0) return;
    if (_srtt == null) {
      _srtt = rtt.toDouble();
      _rttvar = rtt / 2;
    } else {
      _rttvar = (1 - 0.25) * _rttvar! + 0.25 * (_srtt! - rtt).abs();
      _srtt = (1 - 0.125) * _srtt! + 0.125 * rtt;
    }
    _rto = _srtt! + max(100000, 4 * _rttvar!);
    // 不到1秒，就设置为1秒
    _rto = max(_rto, 1000000);
  }

  void fireRequestTimeoutEvent(List<List<int>> requests) {
    if (requests.isEmpty) return;
    for (var f in _handles) {
      Timer.run(() => f(this, requests));
    }
  }

  List<List<int>> get currentRequestBuffer;

  void timeOutErrorHappen();

  void orderResendRequest(int index, int begin, int length, int rensed);

  void startRequestDataTimeout([int times = 0]) {
    _timeout?.cancel();
    var requests = currentRequestBuffer;
    if (requests.isEmpty) return;
    // Дедлайн привязан к САМОМУ СТАРОМУ невыполненному запросу, а не к моменту
    // вызова. Раньше каждый `sendRequest` и каждый пришедший блок отменяли
    // таймер и заводили его заново на полный `_rto`: пир, который отдаёт хоть
    // что-то, бесконечно отодвигал дедлайн зависшего запроса, и тот никогда не
    // добирался до `resend >= 3` — порога, по которому `PeersManager`
    // возвращает под-piece в очередь. Итог: живое соединение, скорость 0.
    var now = DateTime.now().microsecondsSinceEpoch;
    var elapsed = now - requests.first[3];
    // Нижняя граница — защита от busy-loop: если дедлайн уже прошёл, но цикл
    // ниже не набрал ни одного просроченного запроса (дрожание часов),
    // перепланирование не должно крутиться с нулевой задержкой.
    var delay = max(1000, _rto.toInt() - elapsed);
    _timeout = Timer(Duration(microseconds: delay), () {
      if (requests.isEmpty) return;
      if (times + 1 >= 5) {
        timeOutErrorHappen();
        return;
      }

      var now = DateTime.now().microsecondsSinceEpoch;
      var first = requests.first;
      var timeoutR = <List<int>>[];
      while ((now - first[3]) > _rto) {
        var request = requests.removeAt(0);
        timeoutR.add(request);
        if (requests.isEmpty) break;
        first = requests.first;
      }
      for (var request in timeoutR) {
        orderResendRequest(request[0], request[1], request[2], request[4]);
      }

      // Штрафуем окно и удваиваем RTO только если реально что-то просрочено.
      // Таймер теперь может сработать «вхолостую» (дедлайн головы наступил, но
      // она успела уйти из буфера) — схлопывать за это окно до одного блока
      // значило бы душить скорость на ровном месте.
      if (timeoutR.isNotEmpty) {
        times++;
        _rto *= 2;
        _allowWindowSize = DEFAULT_REQUEST_LENGTH;
        fireRequestTimeoutEvent(timeoutR);
      }
      startRequestDataTimeout(times);
    });
  }

  void ackRequest(List<List<int>> requests) {
    if (requests.isEmpty) return;
    var downloaded = 0;
    int? minRtt;
    for (var request in requests) {
      // 重发后收到的不管
      if (request[4] != 0) continue;
      var now = DateTime.now().microsecondsSinceEpoch;
      var rtt = now - request[3];
      minRtt ??= rtt;
      minRtt = min(minRtt, rtt);
      updateRTO(rtt);
      downloaded += request[2];
    }
    if (downloaded == 0 || minRtt == null) return;
    var artt = minRtt;
    var delay_factor = (CCONTROL_TARGET - artt) / CCONTROL_TARGET;
    var window_factor = downloaded / _allowWindowSize;
    var scaled_gain =
        MAX_CWND_INCREASE_REQUESTS_PER_RTT * delay_factor * window_factor;

    _allowWindowSize += scaled_gain.toInt();
    _allowWindowSize = max(DEFAULT_REQUEST_LENGTH, _allowWindowSize);
    _allowWindowSize = min(MAX_WINDOW, _allowWindowSize);
  }

  int get currentWindow {
    var c = _allowWindowSize ~/ DEFAULT_REQUEST_LENGTH;
    // var cw = 2 + (currentSpeed * 500 / DEFAULT_REQUEST_LENGTH).ceil();
    // print('$cw, $c');
    return c;
  }

  void clearCC() {
    _timeout?.cancel();
    _handles.clear();
    _downloadedHistory.clear();
  }
}
