import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_task/torrent_task.dart';

/// Builds a [Torrent] model by hand (no .torrent parsing) from an in-memory
/// file layout, computing the real per-piece SHA1 hashes over the concatenated
/// content so [verifyExistingFiles] has authentic hashes to check against.
///
/// [files] is an ordered list of (relativePathWithinTorrentName, bytes). The
/// torrent name is [name]; each file's on-disk path is
/// `<downloadDir>/<name>/<relativePath>`, matching DownloadFileManager's layout
/// (TorrentFile.path already includes the name as its first segment).
Torrent _buildTorrent({
  required String name,
  required int pieceLength,
  required List<MapEntry<String, List<int>>> files,
}) {
  // Concatenate all file content in order to derive piece hashes.
  final all = <int>[];
  for (final f in files) {
    all.addAll(f.value);
  }
  final totalLength = all.length;

  final piecesCount = (totalLength + pieceLength - 1) ~/ pieceLength;
  final hashes = <String>[];
  for (var i = 0; i < piecesCount; i++) {
    final start = i * pieceLength;
    final end =
        (start + pieceLength) > totalLength ? totalLength : start + pieceLength;
    final digest = sha1.convert(all.sublist(start, end));
    hashes.add(_hex(digest.bytes));
  }

  final infoHashBuffer = Uint8List.fromList(List<int>.generate(20, (i) => i));
  // `info` is only used for re-serialisation; recheck never touches it.
  final torrent =
      Torrent(<String, dynamic>{}, name, _hex(infoHashBuffer), infoHashBuffer);

  var offset = 0;
  for (final f in files) {
    final relPath = f.key;
    final length = f.value.length;
    // TorrentFile.path includes the torrent name as the first path segment,
    // exactly as the real parser produces (p.joinAll([name, ...filePath])).
    final fullPath = p.join(name, relPath);
    torrent.addFile(TorrentFile(p.basename(relPath), fullPath, length, offset));
    offset += length;
  }
  torrent.length = totalLength;
  torrent.pieceLength = pieceLength;
  var lastLen = totalLength % pieceLength;
  if (lastLen == 0) lastLen = pieceLength;
  torrent.lastPriceLength = lastLen;
  for (final h in hashes) {
    torrent.addPiece(h);
  }
  return torrent;
}

String _hex(List<int> bytes) {
  final b = StringBuffer();
  for (final x in bytes) {
    b.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// Write the given torrent files to disk under [dir]. [files] may be a subset
/// of the torrent's files (to simulate a partially-present download); each
/// entry's relative path is resolved against the torrent [name].
Future<void> _writeFiles(
    Directory dir, Torrent t, List<MapEntry<String, List<int>>> files) async {
  for (final entry in files) {
    final f = File(p.join(dir.path, t.name, entry.key));
    await f.create(recursive: true);
    await f.writeAsBytes(entry.value);
  }
}

void main() {
  group('verifyExistingFiles (force recheck)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('recheck_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('(a) all files present & valid -> every piece complete', () async {
      // 3 full pieces + a short last piece, single file.
      const pieceLen = 16;
      final content = List<int>.generate(16 * 3 + 5, (i) => (i * 7) % 256);
      final files = [MapEntry('book.epub', content)];
      final t = _buildTorrent(
          name: 'mybook', pieceLength: pieceLen, files: files);
      await _writeFiles(tmp, t, files);

      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.totalPieces, equals(4));
      expect(r.verifiedPieces, equals(4));
      expect(r.isComplete, isTrue);
      for (var i = 0; i < r.totalPieces; i++) {
        expect(r.bitfield.getBit(i), isTrue, reason: 'piece $i');
      }
    });

    test('(b) one corrupted piece -> that piece not complete, rest complete',
        () async {
      const pieceLen = 16;
      final content = List<int>.generate(16 * 4, (i) => (i * 3) % 256);
      final files = [MapEntry('book.epub', content)];
      final t = _buildTorrent(
          name: 'mybook', pieceLength: pieceLen, files: files);
      // Flip a byte inside piece index 2 BEFORE writing to disk.
      final corrupt = List<int>.from(content);
      corrupt[2 * pieceLen + 3] ^= 0xFF;
      final corruptFiles = [MapEntry('book.epub', corrupt)];
      await _writeFiles(tmp, t, corruptFiles);

      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.totalPieces, equals(4));
      expect(r.verifiedPieces, equals(3));
      expect(r.bitfield.getBit(0), isTrue);
      expect(r.bitfield.getBit(1), isTrue);
      expect(r.bitfield.getBit(2), isFalse, reason: 'corrupted piece');
      expect(r.bitfield.getBit(3), isTrue);
    });

    test('(c) a missing file -> its pieces not complete', () async {
      const pieceLen = 16;
      // Two files, each one full piece, on separate piece boundaries.
      final f1 = List<int>.generate(16, (i) => i);
      final f2 = List<int>.generate(16, (i) => 255 - i);
      final files = [MapEntry('a.bin', f1), MapEntry('b.bin', f2)];
      final t = _buildTorrent(
          name: 'pack', pieceLength: pieceLen, files: files);
      // Write only the first file.
      await _writeFiles(tmp, t, [files[0]]);

      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.totalPieces, equals(2));
      expect(r.bitfield.getBit(0), isTrue, reason: 'present file');
      expect(r.bitfield.getBit(1), isFalse, reason: 'missing file');
      expect(r.verifiedPieces, equals(1));
    });

    test('(d) short last piece verified correctly', () async {
      const pieceLen = 32;
      // 1 full piece + a 5-byte tail.
      final content = List<int>.generate(32 + 5, (i) => (i * 11) % 256);
      final files = [MapEntry('tail.bin', content)];
      final t = _buildTorrent(
          name: 'tailbook', pieceLength: pieceLen, files: files);
      expect(t.lastPriceLength, equals(5));
      await _writeFiles(tmp, t, files);

      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.totalPieces, equals(2));
      expect(r.verifiedPieces, equals(2));
      expect(r.bitfield.getBit(1), isTrue, reason: 'short last piece');
    });

    test('(d2) short last piece corrupted -> only last piece incomplete',
        () async {
      const pieceLen = 32;
      final content = List<int>.generate(32 + 5, (i) => (i * 11) % 256);
      final files = [MapEntry('tail.bin', content)];
      final t = _buildTorrent(
          name: 'tailbook', pieceLength: pieceLen, files: files);
      final corrupt = List<int>.from(content);
      corrupt[32 + 2] ^= 0x01; // inside the last (short) piece
      await _writeFiles(tmp, t, [MapEntry('tail.bin', corrupt)]);

      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.bitfield.getBit(0), isTrue);
      expect(r.bitfield.getBit(1), isFalse);
      expect(r.verifiedPieces, equals(1));
    });

    test('(e) multi-file: a piece straddling two files is verified', () async {
      const pieceLen = 16;
      // f1 = 10 bytes, f2 = 22 bytes. Total = 32 -> 2 pieces.
      //   piece 0 = bytes [0,16): all 10 of f1 + first 6 of f2 (STRADDLE)
      //   piece 1 = bytes [16,32): next 16 of f2
      final f1 = List<int>.generate(10, (i) => i + 1);
      final f2 = List<int>.generate(22, (i) => 100 + i);
      final files = [MapEntry('part1.bin', f1), MapEntry('part2.bin', f2)];
      final t = _buildTorrent(
          name: 'split', pieceLength: pieceLen, files: files);
      await _writeFiles(tmp, t, files);

      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.totalPieces, equals(2));
      expect(r.verifiedPieces, equals(2));
      expect(r.bitfield.getBit(0), isTrue,
          reason: 'piece 0 spans part1.bin + part2.bin');
      expect(r.bitfield.getBit(1), isTrue);
    });

    test('(e2) straddling piece with one of the two files missing is incomplete',
        () async {
      const pieceLen = 16;
      final f1 = List<int>.generate(10, (i) => i + 1);
      final f2 = List<int>.generate(22, (i) => 100 + i);
      final files = [MapEntry('part1.bin', f1), MapEntry('part2.bin', f2)];
      final t = _buildTorrent(
          name: 'split', pieceLength: pieceLen, files: files);
      // Write only part1.bin (the straddling piece 0 needs both).
      await _writeFiles(tmp, t, [files[0]]);

      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.bitfield.getBit(0), isFalse,
          reason: 'piece 0 cannot complete without part2.bin');
      expect(r.bitfield.getBit(1), isFalse);
      expect(r.verifiedPieces, equals(0));
    });

    test('empty download dir -> nothing verified, no throw', () async {
      const pieceLen = 16;
      final content = List<int>.generate(16 * 2, (i) => i);
      final files = [MapEntry('x.bin', content)];
      final t = _buildTorrent(name: 'x', pieceLength: pieceLen, files: files);
      // Do not write any files.
      final r = await verifyExistingFiles(t, tmp.path);
      expect(r.verifiedPieces, equals(0));
      expect(r.isComplete, isFalse);
    });
  });

  group('TorrentTask.recheck integration (before start)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('recheck_task_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('recheck on a complete folder marks state complete & persists',
        () async {
      const pieceLen = 16;
      final content = List<int>.generate(16 * 3 + 7, (i) => (i * 5) % 256);
      final files = [MapEntry('whole.epub', content)];
      final t = _buildTorrent(
          name: 'donebook', pieceLength: pieceLen, files: files);
      await _writeFiles(tmp, t, files);

      final task = TorrentTask.newTask(t, tmp.path);
      final verified = await task.recheck();
      expect(verified, equals(t.pieces.length));

      // The state file must now reflect completion on a freshly reopened
      // StateFile (i.e. the bits were persisted to disk, not just in memory).
      final reopened = await StateFile.getStateFile(tmp.path, t);
      expect(reopened.bitfield.completedPieces.length,
          equals(t.pieces.length));
      await reopened.close();
    });

    test('recheck with a missing file leaves those pieces unset in state',
        () async {
      const pieceLen = 16;
      final f1 = List<int>.generate(16, (i) => i);
      final f2 = List<int>.generate(16, (i) => 200 + (i % 50));
      final files = [MapEntry('a.bin', f1), MapEntry('b.bin', f2)];
      final t = _buildTorrent(
          name: 'partial', pieceLength: pieceLen, files: files);
      await _writeFiles(tmp, t, [files[0]]); // only a.bin

      final task = TorrentTask.newTask(t, tmp.path);
      final verified = await task.recheck();
      expect(verified, equals(1));

      final reopened = await StateFile.getStateFile(tmp.path, t);
      expect(reopened.bitfield.getBit(0), isTrue);
      expect(reopened.bitfield.getBit(1), isFalse);
      await reopened.close();
    });
  });
}
