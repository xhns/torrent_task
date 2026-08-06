import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Отображение «кусок торрента → куски файлов» на границах файлов.
///
/// Многофайловый торрент (а аудиокнига — всегда многофайловый) склеен из файлов
/// встык, и кусок, попавший на стык, обслуживается ДВУМЯ и более файлами
/// одновременно. Здесь проверяется обе стороны этой арифметики — запись
/// (качающий) и чтение (сид) — побайтно против исходника, а не по счётчикам.
void main() {
  /// Полное содержимое торрента одной лентой — эталон для сравнения.
  List<int> concat(List<MapEntry<String, List<int>>> files) {
    final all = <int>[];
    for (final f in files) {
      all.addAll(f.value);
    }
    return all;
  }

  /// Индексы кусков, которые обслуживаются более чем одним файлом.
  List<int> crossFilePieces(Torrent model) {
    final res = <int>[];
    final pl = model.pieceLength!;
    for (var i = 0; i < model.pieces.length; i++) {
      final ps = i * pl;
      final pe = (ps + pl > model.length!) ? model.length! : ps + pl;
      var covering = 0;
      for (final f in model.files) {
        if (f.length == 0) continue;
        if (f.offset < pe && f.offset + f.length > ps) covering++;
      }
      if (covering > 1) res.add(i);
    }
    return res;
  }

  /// Разбивает торрент на запросы (piece, begin, length) размером [sub].
  List<List<int>> requestsOf(Torrent model, int sub) {
    final pl = model.pieceLength!;
    final out = <List<int>>[];
    for (var i = 0; i < model.pieces.length; i++) {
      final ps = i * pl;
      final pe = (ps + pl > model.length!) ? model.length! : ps + pl;
      for (var b = 0; ps + b < pe; b += sub) {
        final len = (sub < pe - ps - b) ? sub : pe - ps - b;
        out.add([i, b, len]);
      }
    }
    return out;
  }

  group('запись: кусок на стыке файлов раскладывается по файлам верно', () {
    /// Скачивает торрент «в пробирке»: гонит все под-piece'ы через
    /// [DownloadFileManager.writeFile] и сверяет каждый файл с исходником.
    Future<void> downloadAndCompare(
        List<MapEntry<String, List<int>>> files, int pieceLength, int sub,
        {int infoHashSeed = 5}) async {
      final tmp = Directory.systemTemp.createTempSync('fb_write_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final model = buildTorrent(
          name: 'book',
          pieceLength: pieceLength,
          files: files,
          infoHashSeed: infoHashSeed);
      final all = concat(files);

      final sf = await StateFile.getStateFile(tmp.path, model);
      final fm =
          await DownloadFileManager.createFileManager(model, tmp.path, sf);
      addTearDown(() async {
        try {
          await fm.close();
        } catch (_) {}
      });

      final written = <List<int>>[];
      final failed = <List<int>>[];
      final allDone = Completer<void>();
      final reqs = requestsOf(model, sub);
      void tick() {
        if (written.length + failed.length == reqs.length &&
            !allDone.isCompleted) {
          allDone.complete();
        }
      }

      fm.onSubPieceWriteComplete((i, b, l) {
        written.add([i, b, l]);
        tick();
      });
      fm.onSubPieceWriteFailed((i, b, l) {
        failed.add([i, b, l]);
        tick();
      });

      for (final r in reqs) {
        final from = r[0] * pieceLength + r[1];
        fm.writeFile(r[0], r[1], all.sublist(from, from + r[2]));
      }
      await allDone.future.timeout(const Duration(seconds: 30));
      expect(failed, isEmpty, reason: 'ни одна запись не должна провалиться');

      await fm.flushFiles({for (var i = 0; i < model.pieces.length; i++) i});
      await fm.close();

      for (final f in files) {
        final onDisk = File(p.join(tmp.path, 'book', f.key));
        expect(onDisk.existsSync(), isTrue,
            reason: '${f.key} должен быть создан на диске');
        final got = onDisk.readAsBytesSync();
        expect(got.length, equals(f.value.length),
            reason: '${f.key}: размер на диске');
        for (var i = 0; i < f.value.length; i++) {
          if (got[i] != f.value[i]) {
            fail('${f.key}: первое расхождение на байте $i '
                '(получено ${got[i]}, ожидалось ${f.value[i]})');
          }
        }
      }
    }

    test('блок пересекает границу двух файлов', () async {
      final files = [
        MapEntry('part1.mp3', pseudoBytes(300 * 1024, 21)),
        MapEntry('part2.mp3', pseudoBytes(220 * 1024, 22)),
      ];
      final model =
          buildTorrent(name: 'book', pieceLength: 32 * 1024, files: files);
      // ПРЕДУСЛОВИЕ: граничный кусок вообще существует. Если бы файлы были
      // выровнены по куску, тест прошёл бы по пустому пути.
      expect(crossFilePieces(model), isNotEmpty,
          reason: 'предусловие: должен быть хотя бы один кусок на стыке');
      await downloadAndCompare(files, 32 * 1024, 16 * 1024);
    });

    test('блок целиком внутри одного файла (файлы выровнены по куску)',
        () async {
      final files = [
        MapEntry('a.mp3', pseudoBytes(64 * 1024, 31)),
        MapEntry('b.mp3', pseudoBytes(64 * 1024, 32)),
      ];
      final model =
          buildTorrent(name: 'book', pieceLength: 32 * 1024, files: files);
      // ПРЕДУСЛОВИЕ: здесь стыков внутри куска НЕТ — проверяем именно
      // «простой» путь, а не граничный.
      expect(crossFilePieces(model), isEmpty,
          reason: 'предусловие: выровненные файлы не дают граничных кусков');
      await downloadAndCompare(files, 32 * 1024, 16 * 1024, infoHashSeed: 6);
    });

    test('блок пересекает три и больше файлов (файлы мельче блока)', () async {
      // Куски 16 КБ, блок 16 КБ, файлы по 1–2 КБ: в один блок попадает 8+ файлов.
      final files = <MapEntry<String, List<int>>>[];
      for (var i = 0; i < 20; i++) {
        files.add(MapEntry(
            'tiny$i.mp3', pseudoBytes(1024 + (i % 2) * 1024 + i * 7, 40 + i)));
      }
      final model =
          buildTorrent(name: 'book', pieceLength: 16 * 1024, files: files);
      final crossing = crossFilePieces(model);
      expect(crossing, isNotEmpty, reason: 'предусловие: стыки внутри кусков');
      // ПРЕДУСЛОВИЕ посильнее: есть кусок, который обслуживают 3+ файла —
      // ради этого тест и написан.
      final pl = model.pieceLength!;
      final maxCovering = crossing.map((i) {
        final ps = i * pl;
        final pe = (ps + pl > model.length!) ? model.length! : ps + pl;
        return model.files
            .where((f) =>
                f.length > 0 && f.offset < pe && f.offset + f.length > ps)
            .length;
      }).reduce((a, b) => a > b ? a : b);
      expect(maxCovering, greaterThanOrEqualTo(3),
          reason: 'предусловие: хотя бы один кусок лежит на 3+ файлах');
      await downloadAndCompare(files, 16 * 1024, 16 * 1024, infoHashSeed: 7);
    });

    test('последний кусок торрента короче piece length', () async {
      final files = [
        MapEntry('a.mp3', pseudoBytes(40 * 1024, 51)),
        MapEntry('b.mp3', pseudoBytes(17 * 1024 + 333, 52)),
      ];
      final model =
          buildTorrent(name: 'book', pieceLength: 32 * 1024, files: files);
      // ПРЕДУСЛОВИЕ: последний кусок действительно неполный.
      expect(model.length! % model.pieceLength!, isNot(0),
          reason: 'предусловие: хвост торрента не выровнен по куску');
      expect(crossFilePieces(model), isNotEmpty,
          reason: 'предусловие: стык файлов внутри куска есть');
      await downloadAndCompare(files, 32 * 1024, 16 * 1024, infoHashSeed: 8);
    });

    test('файлы нулевой длины в середине торрента', () async {
      final files = [
        MapEntry('a.mp3', pseudoBytes(20 * 1024 + 7, 61)),
        MapEntry('empty1.nfo', <int>[]),
        MapEntry('empty2.nfo', <int>[]),
        MapEntry('b.mp3', pseudoBytes(30 * 1024 + 11, 62)),
      ];
      final model =
          buildTorrent(name: 'book', pieceLength: 16 * 1024, files: files);
      // ПРЕДУСЛОВИЕ: нулевые файлы стоят ВНУТРИ куска, а не на его границе —
      // иначе они бы не участвовали в отображении и тест ничего не ловил бы.
      expect(files[0].value.length % model.pieceLength!, isNot(0),
          reason: 'предусловие: пустые файлы попадают в середину куска');
      await downloadAndCompare(files, 16 * 1024, 16 * 1024, infoHashSeed: 9);
    });
  });

  group('чтение (раздача): кусок на стыке файлов склеивается в верном порядке',
      () {
    /// Раскладывает готовые файлы на диск и отдаёт менеджер поверх них.
    Future<DownloadFileManager> seededManager(
        Directory dir, Torrent model, List<MapEntry<String, List<int>>> files,
        {void Function()? register}) async {
      await writeFiles(dir, model, files);
      final sf = await StateFile.getStateFile(dir.path, model);
      return DownloadFileManager.createFileManager(model, dir.path, sf);
    }

    test(
        'блок со стыка отдаётся байт-в-байт, даже когда очередь первого файла '
        'занята', () async {
      final tmp = Directory.systemTemp.createTempSync('fb_read_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final files = [
        MapEntry('part1.mp3', pseudoBytes(300 * 1024, 21)),
        MapEntry('part2.mp3', pseudoBytes(220 * 1024, 22)),
      ];
      final model = buildTorrent(
          name: 'book', pieceLength: 32 * 1024, files: files, infoHashSeed: 11);
      final all = concat(files);

      final crossing = crossFilePieces(model);
      // ПРЕДУСЛОВИЕ: граничный кусок существует, иначе проверять нечего.
      expect(crossing, isNotEmpty,
          reason: 'предусловие: должен быть кусок на стыке файлов');
      final boundaryPiece = crossing.first;

      final fm = await seededManager(tmp, model, files);
      addTearDown(() async {
        try {
          await fm.close();
        } catch (_) {}
      });

      const sub = 16 * 1024;
      final blocks = <String, List<int>>{};
      final got = Completer<void>();
      // 8 «фоновых» чтений грузят очередь ПЕРВОГО файла + 20 граничных.
      const backgroundReads = 8;
      const boundaryReads = 20;
      var seen = 0;
      fm.onSubPieceReadComplete((pi, begin, block) {
        blocks['$pi:$begin:${seen++}'] = block;
        if (seen == backgroundReads + boundaryReads && !got.isCompleted) {
          got.complete();
        }
      });

      // Первый файл получает очередь запросов — его чтение граничного блока
      // завершится ПОЗЖЕ чтения второго файла. Именно на этом расхождении
      // склейка по порядку завершения переставляла куски местами.
      for (var i = 0; i < backgroundReads; i++) {
        fm.readFile(i, 0, sub);
      }
      for (var i = 0; i < boundaryReads; i++) {
        fm.readFile(boundaryPiece, 0, sub);
      }
      await got.future.timeout(const Duration(seconds: 30));

      var checkedBoundary = 0;
      for (final entry in blocks.entries) {
        final parts = entry.key.split(':');
        final pi = int.parse(parts[0]);
        final begin = int.parse(parts[1]);
        final abs = pi * model.pieceLength! + begin;
        final block = entry.value;
        expect(block.length, equals(sub),
            reason: 'блок ($pi,$begin) должен быть полной длины');
        for (var i = 0; i < block.length; i++) {
          if (block[i] != all[abs + i]) {
            fail('блок ($pi,$begin): расхождение на байте $i '
                '(отдано ${block[i]}, в торренте ${all[abs + i]})');
          }
        }
        if (pi == boundaryPiece) checkedBoundary++;
      }
      expect(checkedBoundary, equals(boundaryReads),
          reason: 'все граничные чтения должны быть проверены');
    });

    test('весь торрент, вычитанный через readFile, совпадает с исходником '
        '(в т.ч. мелкие файлы и пустые файлы)', () async {
      final tmp = Directory.systemTemp.createTempSync('fb_read_all_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final files = <MapEntry<String, List<int>>>[
        MapEntry('a.mp3', pseudoBytes(20 * 1024 + 7, 71)),
        MapEntry('empty.nfo', <int>[]),
      ];
      for (var i = 0; i < 12; i++) {
        files.add(MapEntry('tiny$i.mp3', pseudoBytes(1500 + i * 111, 80 + i)));
      }
      files.add(MapEntry('tail.mp3', pseudoBytes(9 * 1024 + 3, 99)));

      final model = buildTorrent(
          name: 'book', pieceLength: 16 * 1024, files: files, infoHashSeed: 12);
      final all = concat(files);
      expect(crossFilePieces(model), isNotEmpty,
          reason: 'предусловие: стыки файлов внутри кусков есть');

      final fm = await seededManager(tmp, model, files);
      addTearDown(() async {
        try {
          await fm.close();
        } catch (_) {}
      });

      final reqs = requestsOf(model, 16 * 1024);
      final done = Completer<void>();
      final received = <String, List<int>>{};
      fm.onSubPieceReadComplete((pi, begin, block) {
        received['$pi:$begin'] = block;
        if (received.length == reqs.length && !done.isCompleted) {
          done.complete();
        }
      });
      for (final r in reqs) {
        fm.readFile(r[0], r[1], r[2]);
      }
      await done.future.timeout(const Duration(seconds: 30));

      for (final r in reqs) {
        final block = received['${r[0]}:${r[1]}'];
        expect(block, isNotNull, reason: 'блок (${r[0]},${r[1]}) не отдан');
        expect(block!.length, equals(r[2]),
            reason: 'блок (${r[0]},${r[1]}): длина');
        final abs = r[0] * model.pieceLength! + r[1];
        for (var i = 0; i < block.length; i++) {
          if (block[i] != all[abs + i]) {
            fail('блок (${r[0]},${r[1]}): расхождение на байте $i');
          }
        }
      }
    });
  });
}
