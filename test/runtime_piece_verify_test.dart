import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_task/torrent_task.dart';
import 'package:torrent_task/src/piece/base_piece_selector.dart';

import 'seeding_support.dart';

/// Рантайм-проверка SHA1 каждого докачанного куска.
///
/// Дефект, ради которого она появилась: бит в bitfield ставился по СЧЁТЧИКУ
/// записанных под-кусков, хэш при загрузке не считался вовсе (только в
/// стартовом recheck). Сид, отдававший перевёрнутые блоки на стыках файлов,
/// доводил качающего до `progress = 1.0` и `onTaskComplete` с битой книгой на
/// диске, а повторный recheck снимал биты — и докачка писала ту же грязь.
void main() {
  group('IsolatePieceVerifier — хэш куска на диске', () {
    late Directory tmp;
    late Torrent model;
    late List<MapEntry<String, List<int>>> files;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('piece_verify_');
      files = [
        MapEntry('part1.bin', pseudoBytes(300 * 1024, 11)),
        MapEntry('part2.bin', pseudoBytes(220 * 1024, 12)),
      ];
      model = buildTorrent(
        name: 'verify-book',
        pieceLength: 32 * 1024,
        files: files,
        infoHashSeed: 91,
      );
      await writeFiles(tmp, model, files);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('целые файлы: каждый кусок подтверждается', () async {
      // ПРЕДУСЛОВИЕ: кусков больше одного и есть кусок на стыке файлов —
      // иначе проверялся бы вырожденный случай.
      expect(model.pieces.length, greaterThan(1));
      expect(300 * 1024 % (32 * 1024), isNot(0),
          reason: 'предусловие: граница файлов не выровнена по куску');

      final verifier = await IsolatePieceVerifier.spawn(model, tmp.path);
      addTearDown(verifier.dispose);

      for (var i = 0; i < model.pieces.length; i++) {
        expect(await verifier.verifyPiece(i), isTrue,
            reason: 'кусок $i лежит на диске целым');
      }
      expect(verifier.failedCount, 0);
    });

    test('испорченный на диске кусок не подтверждается, соседние — да',
        () async {
      const victim = 5;
      final file = File(p.join(tmp.path, model.name, 'part1.bin'));
      final before = await file.readAsBytes();

      // Портим ровно байты куска victim, ничего не сдвигая по длине.
      final raf = await file.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(victim * model.pieceLength!);
      await raf.writeFrom(List.filled(model.pieceLength!, 0xAB));
      await raf.flush();
      await raf.close();

      final after = await file.readAsBytes();
      // ПРЕДУСЛОВИЕ: порча состоялась и длина файла не изменилась — иначе тест
      // прошёл бы «по пустому месту».
      expect(after.length, equals(before.length));
      expect(sha1.convert(after).toString(),
          isNot(equals(sha1.convert(before).toString())),
          reason: 'предусловие: содержимое файла действительно испорчено');

      final verifier = await IsolatePieceVerifier.spawn(model, tmp.path);
      addTearDown(verifier.dispose);

      expect(await verifier.verifyPiece(victim), isFalse);
      expect(await verifier.verifyPiece(victim - 1), isTrue);
      expect(await verifier.verifyPiece(victim + 1), isTrue);
      expect(verifier.failedCount, 1);
    });

    test('отсутствующий на диске файл не подтверждается', () async {
      await File(p.join(tmp.path, model.name, 'part2.bin')).delete();
      final verifier = await IsolatePieceVerifier.spawn(model, tmp.path);
      addTearDown(verifier.dispose);
      // Последний кусок лежит целиком в удалённом файле.
      expect(await verifier.verifyPiece(model.pieces.length - 1), isFalse);
    });
  });

  group('PieceManager — бит ставится только после сверки хэша', () {
    late Torrent model;
    late Bitfield bitfield;

    setUp(() {
      model = buildTorrent(
        name: 'gate-book',
        pieceLength: DEFAULT_REQUEST_LENGTH * 4,
        files: [
          MapEntry('a.bin', pseudoBytes(DEFAULT_REQUEST_LENGTH * 8, 3)),
        ],
        infoHashSeed: 92,
      );
      bitfield = Bitfield.createEmptyBitfield(model.pieces.length);
    });

    /// Дописывает кусок [index] целиком по обычному пути записи под-кусков.
    void fillPiece(PieceManager pm, int index) {
      final piece = pm[index]!;
      for (var i = 0; i < piece.subPiecesCount; i++) {
        final begin = i * DEFAULT_REQUEST_LENGTH;
        piece.subPieceDownloadComplete(begin);
        pm.processSubPieceWriteComplete(index, begin, DEFAULT_REQUEST_LENGTH);
      }
    }

    test('хэш сошёлся — кусок принимается', () async {
      final verifier = _FakeVerifier(true);
      final pm = PieceManager.createPieceManager(
          BasePieceSelector(), model, bitfield,
          verifier: verifier);
      final completed = <int>[];
      final failed = <int>[];
      pm.onPieceComplete(completed.add);
      pm.onPieceVerifyFailed(failed.add);

      fillPiece(pm, 1);
      // ПРЕДУСЛОВИЕ: кусок действительно собран, иначе проверять нечего.
      expect(pm[1]!.isCompleted, isTrue);
      expect(completed, isEmpty,
          reason: 'до вердикта проверки кусок не объявляется готовым');

      await Future.delayed(const Duration(milliseconds: 100));

      expect(verifier.asked, equals([1]));
      expect(completed, equals([1]));
      expect(failed, isEmpty);
      expect(pm[1], isNull, reason: 'принятый кусок уходит из работы');
    });

    test('хэш не сошёлся — кусок НЕ принимается и возвращается в очередь '
        'целиком', () async {
      final verifier = _FakeVerifier(false);
      final pm = PieceManager.createPieceManager(
          BasePieceSelector(), model, bitfield,
          verifier: verifier);
      final completed = <int>[];
      final failed = <int>[];
      pm.onPieceComplete(completed.add);
      pm.onPieceVerifyFailed(failed.add);

      fillPiece(pm, 1);
      // ПРЕДУСЛОВИЕ: кусок собран и очередь докачки пуста — именно из этого
      // состояния он и должен вернуться в работу.
      expect(pm[1]!.isCompleted, isTrue);
      expect(pm[1]!.haveAvalidateSubPiece(), isFalse);

      await Future.delayed(const Duration(milliseconds: 100));

      expect(completed, isEmpty,
          reason: 'несошедшийся кусок не должен объявляться готовым');
      expect(failed, equals([1]));
      final piece = pm[1];
      expect(piece, isNotNull, reason: 'кусок остаётся в работе');
      expect(piece!.isCompleted, isFalse);
      expect(piece.avalidateSubPieceCount, equals(piece.subPiecesCount),
          reason: 'в очередь возвращаются ВСЕ под-куски, а не часть');
      expect(piece.downloadedSubPiecesCount, 0);
      expect(piece.writtingSubPiecesCount, 0);
    });

    test('дубль блока во время проверки не запускает вторую проверку',
        () async {
      final verifier = _FakeVerifier(true);
      final pm = PieceManager.createPieceManager(
          BasePieceSelector(), model, bitfield,
          verifier: verifier);

      fillPiece(pm, 0);
      // Опоздавший дубль последнего блока — пока хэш ещё считается.
      pm.processSubPieceWriteComplete(
          0, DEFAULT_REQUEST_LENGTH * 3, DEFAULT_REQUEST_LENGTH);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(verifier.asked, equals([0]),
          reason: 'проверка куска запускается ровно один раз');
    });

    test('перекачанный кусок принимается со второй попытки', () async {
      final verifier = _FakeVerifier(false);
      final pm = PieceManager.createPieceManager(
          BasePieceSelector(), model, bitfield,
          verifier: verifier);
      final completed = <int>[];
      pm.onPieceComplete(completed.add);

      fillPiece(pm, 1);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(completed, isEmpty, reason: 'предусловие: первая попытка отбита');

      // Источник исправился — качаем тот же кусок заново.
      verifier.result = true;
      fillPiece(pm, 1);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(completed, equals([1]));
      expect(verifier.asked, equals([1, 1]));
    });
  });

  group('blameForBadPiece — кого наказывать за битый кусок', () {
    test('единственный источник виноват целиком', () {
      expect(blameForBadPiece({'a:1': 8}), equals('a:1'));
    });

    test('большинство блоков — виноват', () {
      expect(blameForBadPiece({'a:1': 7, 'b:2': 1}), equals('a:1'));
    });

    test('ровно половина — не большинство, не наказываем никого', () {
      expect(blameForBadPiece({'a:1': 4, 'b:2': 4}), isNull);
    });

    test('раздробленный вклад без большинства — не наказываем никого', () {
      expect(blameForBadPiece({'a:1': 3, 'b:2': 3, 'c:3': 2}), isNull);
    });

    test('пустой вклад — некого наказывать', () {
      expect(blameForBadPiece(const {}), isNull);
    });
  });

  group('Сквозной прогон с сидом, отдающим битые данные', () {
    test('качающий не рапортует успех и в итоге отключает битый сид',
        () async {
      final tmp = await Directory.systemTemp.createTemp('bad_seed_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final files = [MapEntry('book.bin', pseudoBytes(520 * 1024, 31))];
      final model = buildTorrent(
        name: 'bad-seed-book',
        pieceLength: 32 * 1024,
        files: files,
        infoHashSeed: 93,
      );

      final seedDir = Directory(p.join(tmp.path, 'seed'))..createSync();
      final leechDir = Directory(p.join(tmp.path, 'leech'))..createSync();
      await writeFiles(seedDir, model, files);

      final seed = TorrentTask.newTask(model, seedDir.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      // Сид проверяет ЦЕЛЫЕ файлы и объявляет себя полным...
      expect(await seed.recheck(), equals(model.pieces.length),
          reason: 'предусловие: сид полон на момент recheck');
      final seedMap = await seed.start();
      addTearDown(seed.stop);

      // ...а потом его копия портится (ровно так ведёт себя сид со старым
      // дефектом склейки блоков: bitfield полный, байты — нет).
      const victim = 5;
      final seedFile = File(p.join(seedDir.path, model.name, 'book.bin'));
      final lengthBefore = await seedFile.length();
      final raf = await seedFile.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(victim * model.pieceLength!);
      await raf.writeFrom(List.filled(model.pieceLength!, 0x5A));
      await raf.flush();
      await raf.close();
      expect(await seedFile.length(), equals(lengthBefore),
          reason: 'предусловие: порча не меняет длину файла');

      final leech = TorrentTask.newTask(model, leechDir.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      expect(await leech.recheck(), equals(0),
          reason: 'предусловие: качающему нужно качать всё');
      await leech.start();
      addTearDown(leech.stop);

      var completeFired = false;
      leech.onTaskComplete(() => completeFired = true);

      final seedAddress =
          CompactAddress(await _localAddress(), seedMap['tcp_socket'] as int);
      leech.addPeer(seedAddress);

      // Ждём, пока качающий упрётся: битый сид отключён за перебор битых
      // кусков.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline) && leech.bannedPeerIds.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      // Дать возможному (ошибочному) завершению проявиться.
      await Future.delayed(const Duration(seconds: 2));

      // ПРЕДУСЛОВИЕ: обмен реально был — иначе тест зелен ни от чего.
      expect(leech.downloaded, greaterThan(0),
          reason: 'предусловие: качающий что-то скачал у сида');

      expect(completeFired, isFalse,
          reason: 'onTaskComplete с несошедшимися кусками — тот самый дефект');
      expect(leech.progress, lessThan(1.0),
          reason: 'битый кусок не имеет права попасть в bitfield');
      expect(leech.corruptedPiecesCount, greaterThanOrEqualTo(3),
          reason: 'кусок обязан браковаться и перекачиваться, а не приниматься');
      // Сид держит с нами ДВА соединения: наше исходящее на его слушающий порт
      // и его входящее (эфемерный порт) — их приносит LSD. Источник обязан
      // опознаваться как ОДИН (по peer_id из рукопожатия): иначе вклад в кусок
      // делится пополам, большинства нет и наказывать оказывается некого.
      expect(leech.bannedPeerIds, hasLength(1),
          reason: 'единственный битый источник — ровно один бан, '
              'сколько бы соединений он ни держал');
      expect(leech.connectedPeersNumber, isZero,
          reason: 'все соединения забаненного источника разорваны');

      // Ровно один кусок битый — остальные 16 обязаны доехать и лечь в
      // bitfield, иначе проверка «ломает» здоровую загрузку.
      expect(leech.downloaded,
          equals(model.length! - model.pieceLength!),
          reason: 'все куски кроме битого приняты');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('битый сид не мешает докачать у честного', () async {
      final tmp = await Directory.systemTemp.createTemp('mixed_seed_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final files = [MapEntry('book.bin', pseudoBytes(520 * 1024, 41))];
      final model = buildTorrent(
        name: 'mixed-seed-book',
        pieceLength: 32 * 1024,
        files: files,
        infoHashSeed: 94,
      );

      final goodDir = Directory(p.join(tmp.path, 'good'))..createSync();
      final badDir = Directory(p.join(tmp.path, 'bad'))..createSync();
      final leechDir = Directory(p.join(tmp.path, 'leech'))..createSync();
      await writeFiles(goodDir, model, files);
      await writeFiles(badDir, model, files);

      final good = TorrentTask.newTask(model, goodDir.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      expect(await good.recheck(), equals(model.pieces.length));
      final goodMap = await good.start();
      addTearDown(good.stop);

      final bad = TorrentTask.newTask(model, badDir.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      expect(await bad.recheck(), equals(model.pieces.length));
      final badMap = await bad.start();
      addTearDown(bad.stop);

      // Портим копию второго сида уже после его recheck.
      final badFile = File(p.join(badDir.path, model.name, 'book.bin'));
      final raf = await badFile.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(3 * model.pieceLength!);
      await raf.writeFrom(List.filled(model.pieceLength! * 2, 0x11));
      await raf.flush();
      await raf.close();

      final leech = TorrentTask.newTask(model, leechDir.path,
        listenPort: kEphemeralListenPort, enablePortMapping: false);
      expect(await leech.recheck(), equals(0));
      await leech.start();
      addTearDown(leech.stop);

      final done = Completer<void>();
      leech.onTaskComplete(() {
        if (!done.isCompleted) done.complete();
      });
      final host = await _localAddress();
      leech.addPeer(CompactAddress(host, badMap['tcp_socket'] as int));
      leech.addPeer(CompactAddress(host, goodMap['tcp_socket'] as int));

      await done.future.timeout(const Duration(seconds: 120),
          onTimeout: () => throw StateError(
              'докачка у честного сида не завершилась: '
              'прогресс ${leech.progress}, '
              'брак ${leech.corruptedPiecesCount}'));
      await Future.delayed(const Duration(seconds: 2));

      final src = File(p.join(goodDir.path, model.name, 'book.bin'));
      final dst = File(p.join(leechDir.path, model.name, 'book.bin'));
      expect(sha1.convert(await dst.readAsBytes()).toString(),
          equals(sha1.convert(await src.readAsBytes()).toString()),
          reason: 'файл обязан совпасть с оригиналом побайтно');
      expect(leech.progress, equals(1.0));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

/// Проверяльщик-заглушка: возвращает заранее заданный вердикт и помнит, о чём
/// его спрашивали.
class _FakeVerifier implements PieceVerifier {
  bool result;
  final List<int> asked = [];

  _FakeVerifier(this.result);

  @override
  Future<bool> verifyPiece(int pieceIndex) {
    asked.add(pieceIndex);
    return Future.value(result);
  }

  @override
  Future<void> dispose() async {}
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
