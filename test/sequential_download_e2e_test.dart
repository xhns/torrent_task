import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Сквозной прогон последовательного режима: качающий с `sequential: true`
/// забирает куски в ЗАДАННОМ порядке, поэтому нужный файл дочитывается до
/// последнего байта ЗАДОЛГО ДО конца загрузки — ровно это и продаёт режим
/// «слушать по мере скачивания».
///
/// Порядок здесь намеренно ОБРАТЕН порядку файлов в торренте: так проверяется,
/// что режим идёт по `pieceOrder` (порядок воспроизведения), а не просто по
/// возрастанию индекса куска — иначе тест прошёл бы и на естественном порядке,
/// ничего не доказав.
///
/// Тест намеренно НЕ ждёт конца загрузки: завершение — отдельная механика
/// движка (запись → SHA1 → bitfield), у неё своя редкая гонка на самом финише
/// (в приложении её сторожит FinishStallDetector + авто-recheck), и мешать её
/// сюда значило бы получить мигающий тест не про то, что он проверяет.
void main() {
  test('sequential: файл из начала pieceOrder готов раньше конца загрузки',
      () async {
    final tmp = await Directory.systemTemp.createTemp('seq_dl_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    final files = [
      MapEntry('01.bin', pseudoBytes(256 * 1024, 31)),
      MapEntry('02.bin', pseudoBytes(256 * 1024, 32)),
      MapEntry('03.bin', pseudoBytes(256 * 1024, 33)),
    ];
    final model = buildTorrent(
      name: 'seq-book',
      pieceLength: 32 * 1024,
      files: files,
      infoHashSeed: 83,
    );

    // «Порядок воспроизведения» = 03, 02, 01 (обратный торрентному).
    final playback = ['03.bin', '02.bin', '01.bin'];
    final order = <int>[];
    for (final name in playback) {
      final f = model.files.firstWhere((f) => f.path.endsWith(name));
      final range = pieceRangeOfFile(
          offset: f.offset, length: f.length, pieceLength: model.pieceLength!)!;
      for (var i = range.first; i <= range.last; i++) {
        if (!order.contains(i)) order.add(i);
      }
    }
    // ПРЕДУСЛОВИЕ: порядок действительно перевёрнут, иначе тест ничего не ловит.
    expect(order.first, greaterThan(order.last),
        reason: 'предусловие: первым качаем кусок с БОЛЬШИМ индексом');

    final seedDir = Directory(p.join(tmp.path, 'seed'))..createSync();
    final leechDir = Directory(p.join(tmp.path, 'leech'))..createSync();
    await writeFiles(seedDir, model, files);

    final seed = TorrentTask.newTask(model, seedDir.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
    expect(await seed.recheck(), equals(model.pieces.length),
        reason: 'предусловие: сид полон');
    final seedMap = await seed.start();
    addTearDown(seed.stop);

    final leech = TorrentTask.newTask(model, leechDir.path,
        listenPort: kEphemeralListenPort,
        enablePortMapping: false,
        sequential: true,
        pieceOrder: order);
    expect(await leech.recheck(), equals(0),
        reason: 'предусловие: у качающего нет ни одного куска');
    expect(leech.completedFiles, isEmpty,
        reason: 'предусловие: готовых файлов нет');
    await leech.start();
    addTearDown(leech.stop);

    leech.addPeer(
        CompactAddress(await _localAddress(), seedMap['tcp_socket'] as int));

    // Ждём ПЕРВЫЙ дозревший файл и снимаем состояние ровно в этот момент.
    final firstReady = Completer<({Set<String> ready, double progress})>();
    final poll = Timer.periodic(const Duration(milliseconds: 5), (t) {
      final ready = leech.completedFiles;
      if (ready.isEmpty || firstReady.isCompleted) return;
      t.cancel();
      firstReady.complete((ready: ready, progress: leech.progress));
    });
    addTearDown(poll.cancel);

    final snapshot = await firstReady.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw StateError(
            'ни один файл не дозрел: прогресс ${leech.progress}'));

    expect(snapshot.ready.single, endsWith('03.bin'),
        reason: 'первым обязан дозреть файл из начала pieceOrder, '
            'а готовы: ${snapshot.ready}');
    // Главное обещание режима: слушать можно, пока книга ещё качается.
    expect(snapshot.progress, lessThan(1.0),
        reason: 'файл готов, а загрузка ещё идёт');

    // «Готов» обязано означать «побайтно верен»: пустое обещание готовности
    // хуже отсутствия фичи — плеер откроет обрезанный файл.
    final src = File(p.join(seedDir.path, model.name, '03.bin'));
    final dst = File(p.join(leechDir.path, model.name, '03.bin'));
    expect(sha1.convert(await dst.readAsBytes()).toString(),
        equals(sha1.convert(await src.readAsBytes()).toString()),
        reason: '03.bin объявлен готовым — обязан совпадать с оригиналом');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

InternetAddress? _cached;

/// Не loopback: TorrentTask намеренно закрывает входящие с 127.0.0.1.
Future<InternetAddress> _localAddress() async {
  if (_cached != null) return _cached!;
  final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
  for (final i in ifs) {
    for (final a in i.addresses) {
      if (!a.isLoopback) {
        _cached = a;
        return a;
      }
    }
  }
  throw StateError('нет не-loopback IPv4 адреса — тесту не через что ходить');
}
