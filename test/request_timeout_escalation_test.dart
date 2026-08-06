import 'dart:async';

import 'package:test/test.dart';

import 'package:torrent_task/src/peer/congestion_control.dart';
import 'package:torrent_task/src/utils.dart';

/// Зависший запрос обязан эскалировать за конечное время, даже если пиру
/// продолжают слаться новые запросы.
///
/// Баг: `startRequestDataTimeout` отменял таймер и заводил его заново на полный
/// `_rto` от МОМЕНТА ВЫЗОВА. Вызывается он из `sendRequest` и из обработчика
/// пришедших блоков, поэтому пир, отдающий хоть что-то, бесконечно отодвигал
/// дедлайн зависшего запроса. Тот никогда не добирался до `resend >= 3` —
/// порога, по которому `PeersManager._processRequestTimeout` возвращает
/// под-piece в очередь докачки.
class _FakeCC with CongestionControl {
  final List<List<int>> buffer = [];

  /// Запросы, отправленные на переотправку (эскалация).
  final List<List<int>> resent = [];

  int timeoutErrors = 0;

  @override
  List<List<int>> get currentRequestBuffer => buffer;

  @override
  void timeOutErrorHappen() => timeoutErrors++;

  @override
  void orderResendRequest(int index, int begin, int length, int resend) {
    resent.add([index, begin, length, resend + 1]);
    buffer.add([
      index,
      begin,
      length,
      DateTime.now().microsecondsSinceEpoch,
      resend + 1,
    ]);
  }

  /// Кладёт запрос в буфер так, как это делает `Peer.addRequest`.
  void addRequest(int index, int begin) {
    buffer.add([
      index,
      begin,
      DEFAULT_REQUEST_LENGTH,
      DateTime.now().microsecondsSinceEpoch,
      0,
    ]);
  }
}

void main() {
  group('CongestionControl.startRequestDataTimeout', () {
    test('новые запросы НЕ отодвигают дедлайн зависшего запроса', () async {
      final cc = _FakeCC();
      // Приводим RTO к минимуму (1с) — иначе стартовые 10с делают тест вечным.
      cc.updateRTO(1);

      cc.addRequest(0, 0); // зависший запрос: ответа по нему не будет никогда
      cc.startRequestDataTimeout();

      // ПРЕДУСЛОВИЕ: пока RTO не истёк, эскалации быть не должно — иначе тест
      // прошёл бы «ни от чего».
      await Future.delayed(const Duration(milliseconds: 300));
      expect(cc.resent, isEmpty,
          reason: 'предусловие: до истечения RTO эскалации нет');

      // Имитируем живого пира: каждые 100мс уходит новый запрос, и каждый из
      // них перезапускает таймер. Всего 1.4с — заведомо больше RTO (1с).
      for (var i = 0; i < 11; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        cc.addRequest(0, (i + 1) * DEFAULT_REQUEST_LENGTH);
        cc.startRequestDataTimeout();
      }

      // Со старым поведением дедлайн уезжал бы на 1с вперёд от ПОСЛЕДНЕГО
      // вызова, и к этому моменту зависший запрос не эскалировал бы ни разу.
      await Future.delayed(const Duration(milliseconds: 200));
      expect(cc.resent, isNotEmpty,
          reason: 'зависший запрос обязан эскалировать за конечное время');
      expect(cc.resent.first.sublist(0, 2), [0, 0],
          reason: 'эскалирует именно самый старый (зависший) запрос');
      expect(cc.resent.first[3], 1, reason: 'счётчик resend вырос');
    });

    test('пустой буфер не заводит таймер', () async {
      final cc = _FakeCC();
      cc.updateRTO(1);
      cc.startRequestDataTimeout();
      await Future.delayed(const Duration(milliseconds: 1200));
      expect(cc.resent, isEmpty);
      expect(cc.timeoutErrors, 0);
    });

    test('отвеченный вовремя запрос не эскалирует', () async {
      final cc = _FakeCC();
      cc.updateRTO(1);
      cc.addRequest(0, 0);
      cc.startRequestDataTimeout();

      // Пир ответил через 200мс: запрос уходит из буфера, как в
      // `Peer._processReceivePieces` (removeRequest + ackRequest + рестарт).
      await Future.delayed(const Duration(milliseconds: 200));
      cc.buffer.removeAt(0);
      cc.ackRequest([]);
      cc.startRequestDataTimeout();

      await Future.delayed(const Duration(milliseconds: 1500));
      expect(cc.resent, isEmpty,
          reason: 'запрос, на который пришёл ответ, эскалировать не должен');
    });
  });
}
