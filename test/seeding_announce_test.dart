import 'dart:io';

import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Блокер A: задача, стартующая с уже полным торрентом, обязана анонсироваться
/// трекеру. До фикса она уходила в ветку `_tracker.complete()`, которая
/// перебирает пустую карту трекеров, — трекер не видел ни одного обращения,
/// и сида никто не мог найти («0 роздано» после перезапуска приложения).
void main() {
  group('Блокер A — анонс сида', () {
    late Directory tmp;
    late StubTracker tracker;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('seed_announce_');
      tracker = await StubTracker.start();
    });

    tearDown(() async {
      await tracker.stop();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('полный на старте торрент анонсирует started с left=0', () async {
      final files = [
        MapEntry('part1.mp3', pseudoBytes(40 * 1024, 1)),
        MapEntry('part2.mp3', pseudoBytes(25 * 1024, 2)),
      ];
      final model = buildTorrent(
        name: 'seed-book',
        pieceLength: 16 * 1024,
        files: files,
        announces: [tracker.announceUrl],
      );
      await writeFiles(tmp, model, files);

      final task = TorrentTask.newTask(model, tmp.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      final verified = await task.recheck();

      // ПРЕДУСЛОВИЕ. Тест проверяет поведение ветки «торрент уже полон»; если
      // recheck не подтвердил полноту, задача пойдёт обычным путём загрузки и
      // анонс случится сам собой — тест позеленел бы ни от чего.
      expect(verified, equals(model.pieces.length),
          reason: 'сид должен стартовать с полностью проверенным торрентом');

      final map = await task.start();
      final listeningPort = map['tcp_socket'] as int;

      await _waitFor(() => tracker.hits.isNotEmpty);
      await task.stop();

      expect(tracker.hits, isNotEmpty,
          reason: 'полный торрент обязан анонсироваться, а не молчать');
      final started = tracker.hitsWithEvent('started');
      expect(started, isNotEmpty,
          reason: 'первый анонс по BEP 3 — started');
      expect(started.first.left, equals(0),
          reason: 'сид сообщает left=0 — это и делает его сидом для трекера');
      expect(started.first.port, equals(listeningPort),
          reason: 'трекеру должен уходить наш реально слушающий TCP-порт');
    });

    test('completed НЕ шлётся, если торрент был полон уже на старте', () async {
      // BEP 3: `completed` must not be sent if the download was already
      // complete when the client started.
      final files = [MapEntry('only.mp3', pseudoBytes(20 * 1024, 7))];
      final model = buildTorrent(
        name: 'seed-book-2',
        pieceLength: 16 * 1024,
        files: files,
        announces: [tracker.announceUrl],
        infoHashSeed: 5,
      );
      await writeFiles(tmp, model, files);

      final task = TorrentTask.newTask(model, tmp.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      final verified = await task.recheck();
      expect(verified, equals(model.pieces.length),
          reason: 'предусловие: торрент полон на старте');

      await task.start();
      await _waitFor(() => tracker.hits.isNotEmpty);
      await task.stop();

      // ПРЕДУСЛОВИЕ. «completed не пришёл» ничего не стоит, если до трекера
      // вообще не дошло ни одного запроса: проверка молча прошла бы по пустому
      // пути. Сначала убеждаемся, что связь с трекером состоялась.
      expect(tracker.hitsWithEvent('started'), isNotEmpty,
          reason: 'предусловие: анонс до трекера дошёл');
      expect(tracker.hitsWithEvent('completed'), isEmpty,
          reason: 'уже полный на старте торрент не рапортует completed');
    });
  });
}

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future.delayed(const Duration(milliseconds: 20));
  }
}
