import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Сквозной прогон: два настоящих [TorrentTask] в одном процессе — полный сид и
/// пустой качающий — переливают торрент друг другу по TCP.
///
/// Трекер здесь НАМЕРЕННО недоступен (announce-url на закрытый порт), а пир
/// задаётся напрямую через публичный `addPeer`. Это воспроизводит путь, на
/// котором живой стенд поймал регрессию: `Tracker.complete()`, не достучавшись,
/// сам делает `dispose`, после чего возобновление анонсов бросало исключение из
/// `void ... async`-обработчика — unhandled, процесс качающего умирал ровно в
/// момент завершения загрузки и не дописывал файлы.
void main() {
  test('качающий скачивает у сида целиком и переживает мёртвый трекер',
      () async {
    final tmp = await Directory.systemTemp.createTemp('dl_then_seed_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    // Порт, который гарантированно никто не слушает: занимаем и отпускаем.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadTrackerPort = probe.port;
    await probe.close();

    // Один файл намеренно: на многофайловом торренте кусок, попадающий на
    // границу файлов, приезжает битым — это ПРЕДСУЩЕСТВУЮЩИЙ дефект отображения
    // смещений, воспроизводится и на main, к раздаче отношения не имеет.
    // Отдельный воспроизводитель — тест ниже.
    final files = [
      MapEntry('single.bin', pseudoBytes(520 * 1024, 21)),
    ];
    final model = buildTorrent(
      name: 'e2e-book',
      pieceLength: 32 * 1024,
      files: files,
      announces: [Uri.parse('http://127.0.0.1:$deadTrackerPort/announce')],
      infoHashSeed: 67,
    );

    final seedDir = Directory(p.join(tmp.path, 'seed'))..createSync();
    final leechDir = Directory(p.join(tmp.path, 'leech'))..createSync();
    await writeFiles(seedDir, model, files);

    final seed = TorrentTask.newTask(model, seedDir.path);
    final seedVerified = await seed.recheck();
    // ПРЕДУСЛОВИЕ: сиду есть что отдавать.
    expect(seedVerified, equals(model.pieces.length),
        reason: 'предусловие: сид полон');
    final seedMap = await seed.start();
    addTearDown(seed.stop);
    final seedPort = seedMap['tcp_socket'] as int;

    final leech = TorrentTask.newTask(model, leechDir.path);
    final leechVerified = await leech.recheck();
    // ПРЕДУСЛОВИЕ: качающему действительно нужно качать, иначе тест прошёл бы
    // по пути «всё уже на месте» и ничего бы не проверил.
    expect(leechVerified, equals(0),
        reason: 'предусловие: у качающего нет ни одного куска');
    await leech.start();
    addTearDown(leech.stop);

    final done = Completer<void>();
    leech.onTaskComplete(() {
      if (!done.isCompleted) done.complete();
    });

    leech.addPeer(CompactAddress(await _localAddress(), seedPort));

    await done.future.timeout(const Duration(seconds: 90),
        onTimeout: () => throw StateError(
            'загрузка не завершилась: прогресс ${leech.progress}'));

    // Дать обработчику завершения доработать (именно в нём жило падение на
    // мёртвом трекере) и дописать хвосты на диск.
    await Future.delayed(const Duration(seconds: 3));

    // Файлы обязаны совпасть побайтно — прогресс сам по себе ничего не значит,
    // если данные не долетели на диск.
    for (final f in files) {
      final src = File(p.join(seedDir.path, model.name, f.key));
      final dst = File(p.join(leechDir.path, model.name, f.key));
      expect(await dst.exists(), isTrue, reason: '${f.key} должен быть создан');
      expect(sha1.convert(await dst.readAsBytes()).toString(),
          equals(sha1.convert(await src.readAsBytes()).toString()),
          reason: '${f.key} у качающего обязан совпадать с оригиналом');
    }

    expect(leech.progress, equals(1.0));
    // Данные действительно приехали по сети: качающий стартовал с нуля кусков и
    // знал ровно одного пира — сида.
    expect(leech.downloaded, equals(model.length),
        reason: 'скачано должно совпасть с размером торрента');
    // Намеренно НЕ проверяем seed.uploaded: этот счётчик персистится только
    // порциями по MAX_UPLOADED_NOTIFY_SIZE (10 МБ) и на раздаче меньше порции
    // остаётся нулём. Отдельный дефект учёта, см. отчёт.
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ВОСПРОИЗВОДИТЕЛЬ ПРЕДСУЩЕСТВУЮЩЕГО ДЕФЕКТА, не относящегося к раздаче.
  //
  // На многофайловом торренте кусок, попадающий на границу двух файлов,
  // записывается качающим не туда: в хвост первого файла приезжает начало
  // второго. Задача при этом рапортует progress=1.0 и зовёт onTaskComplete, а
  // повторный recheck находит 16 из 17 кусков — то есть битый кусок проходит
  // как завершённый.
  //
  // Аудиокниги — всегда многофайловые торренты с произвольными размерами mp3,
  // так что граничный кусок есть у каждой пары соседних файлов.
  //
  // Проверено на нетронутом main (git worktree): расхождение бит-в-бит то же
  // самое (firstDiff=294912, 12240 байт; recheck 16/17). Ни один фикс раздачи
  // из этой ветки к дефекту отношения не имеет — он в отображении смещений
  // piece -> файл, а не в сети.
  //
  // Тест выключен намеренно: чинить отображение смещений — отдельная задача,
  // но терять воспроизводитель нельзя.
  test('многофайловый торрент: кусок на границе файлов приезжает битым',
      () async {
    final tmp = await Directory.systemTemp.createTemp('cross_file_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    final files = [
      MapEntry('part1.bin', pseudoBytes(300 * 1024, 21)),
      MapEntry('part2.bin', pseudoBytes(220 * 1024, 22)),
    ];
    final model = buildTorrent(
      name: 'cross-file-book',
      pieceLength: 32 * 1024,
      files: files,
      infoHashSeed: 71,
    );
    // 300 КБ = 9.375 куска: кусок #9 лежит на границе part1/part2.
    expect(300 * 1024 % (32 * 1024), isNot(0),
        reason: 'предусловие: граница файлов не выровнена по куску, '
            'иначе граничного куска просто не существует');

    final seedDir = Directory(p.join(tmp.path, 'seed'))..createSync();
    final leechDir = Directory(p.join(tmp.path, 'leech'))..createSync();
    await writeFiles(seedDir, model, files);

    final seed = TorrentTask.newTask(model, seedDir.path);
    expect(await seed.recheck(), equals(model.pieces.length));
    final seedMap = await seed.start();
    addTearDown(seed.stop);

    final leech = TorrentTask.newTask(model, leechDir.path);
    expect(await leech.recheck(), equals(0));
    await leech.start();
    addTearDown(leech.stop);

    final done = Completer<void>();
    leech.onTaskComplete(() {
      if (!done.isCompleted) done.complete();
    });
    leech.addPeer(
        CompactAddress(await _localAddress(), seedMap['tcp_socket'] as int));
    await done.future.timeout(const Duration(seconds: 90));
    await Future.delayed(const Duration(seconds: 2));

    for (final f in files) {
      final src = File(p.join(seedDir.path, model.name, f.key));
      final dst = File(p.join(leechDir.path, model.name, f.key));
      expect(sha1.convert(await dst.readAsBytes()).toString(),
          equals(sha1.convert(await src.readAsBytes()).toString()),
          reason: '${f.key} обязан совпадать с оригиналом');
    }
  },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: 'ПРЕДСУЩЕСТВУЮЩИЙ дефект отображения piece -> файл (есть и на '
          'main, к раздаче отношения не имеет): кусок на границе файлов '
          'приезжает битым, задача при этом рапортует 100%. Снять skip, когда '
          'отображение смещений будет починено.');
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
