import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path_pkg;
import 'package:torrent_model/torrent_model.dart';

import '../peer/bitfield.dart';

/// Maximum number of bytes read from disk in a single I/O call while hashing a
/// piece. Pieces can be large (multi-MiB) and books even larger, so reads are
/// chunked to keep peak memory bounded instead of slurping a whole piece (or
/// file) into RAM at once.
const _readChunkSize = 1 << 16; // 64 KiB

/// Result of a force re-verify ("recheck") pass over the files already present
/// on disk for a torrent.
class RecheckResult {
  /// Reconstructed bitfield: a bit is set iff the corresponding piece was read
  /// from disk and its SHA1 matched [Torrent.pieces].
  final Bitfield bitfield;

  /// Number of pieces whose on-disk bytes hashed to the expected SHA1.
  final int verifiedPieces;

  /// Total number of pieces in the torrent.
  final int totalPieces;

  RecheckResult(this.bitfield, this.verifiedPieces, this.totalPieces);

  /// Whether every piece verified (the torrent is complete on disk).
  bool get isComplete => verifiedPieces == totalPieces && totalPieces > 0;
}

/// Describes the slice of a single on-disk file that backs part of a piece.
class _PieceFileSegment {
  /// Absolute path of the file on disk.
  final String filePath;

  /// Byte offset within the file at which this segment starts.
  final int fileOffset;

  /// Number of bytes this file contributes to the piece.
  final int length;

  _PieceFileSegment(this.filePath, this.fileOffset, this.length);
}

/// Force re-verify the files already present in [downloadDir] against the piece
/// hashes in [metainfo], returning a [RecheckResult] whose bitfield marks every
/// piece whose bytes are present and hash-correct.
///
/// The directory layout matches [DownloadFileManager]: every torrent file is
/// stored at `path_pkg.join(downloadDir, file.path)` (where `file.path` already
/// includes the torrent name as its first segment). This mirrors the layout the
/// downloader writes to, so an existing download (or a folder of previously
/// fetched books the user simply pointed the app at) is recognised without a
/// state file.
///
/// Pieces are read in [_readChunkSize] chunks; a missing file, a file shorter
/// than required, or a SHA1 mismatch leaves the piece's bit unset. The last
/// (possibly short) piece is hashed at its true length ([Torrent.lastPriceLength]),
/// and pieces that span multiple files are reassembled across file boundaries.
///
/// This function opens files read-only and closes every handle before
/// returning, even on error. It does not create, truncate, or otherwise mutate
/// any file on disk.
Future<RecheckResult> verifyExistingFiles(
    Torrent metainfo, String downloadDir) async {
  final pieceLength = metainfo.pieceLength!;
  final lastPieceLength = metainfo.lastPriceLength!;
  final piecesNum = metainfo.pieces.length;
  final bitfield = Bitfield.createEmptyBitfield(piecesNum);

  // Resolve each torrent file to an absolute path + global byte range, once.
  final segments = <_FileLayout>[];
  for (final f in metainfo.files) {
    final absPath = path_pkg.join(downloadDir, f.path);
    segments.add(_FileLayout(absPath, f.offset, f.length));
  }

  // Cache of open read handles + an "exists/usable" flag, keyed by file path,
  // so a multi-file run does not re-open the same file for every piece.
  final openFiles = <String, RandomAccessFile?>{};

  Future<RandomAccessFile?> handleFor(String filePath) async {
    if (openFiles.containsKey(filePath)) return openFiles[filePath];
    RandomAccessFile? raf;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        raf = await file.open(mode: FileMode.read);
      }
    } catch (_) {
      raf = null;
    }
    openFiles[filePath] = raf;
    return raf;
  }

  var verified = 0;
  try {
    for (var pieceIndex = 0; pieceIndex < piecesNum; pieceIndex++) {
      final thisPieceLength =
          (pieceIndex == piecesNum - 1) ? lastPieceLength : pieceLength;
      final pieceStart = pieceIndex * pieceLength;
      final pieceEnd = pieceStart + thisPieceLength;

      // Which file slices cover this piece, in order.
      final pieceSegments = <_PieceFileSegment>[];
      for (final layout in segments) {
        final fileStart = layout.offset;
        final fileEnd = layout.offset + layout.length;
        // Overlap of [pieceStart, pieceEnd) with [fileStart, fileEnd).
        final overlapStart =
            pieceStart > fileStart ? pieceStart : fileStart;
        final overlapEnd = pieceEnd < fileEnd ? pieceEnd : fileEnd;
        if (overlapEnd <= overlapStart) continue;
        pieceSegments.add(_PieceFileSegment(
          layout.filePath,
          overlapStart - fileStart,
          overlapEnd - overlapStart,
        ));
      }

      final ok = await _verifyPiece(
        expectedHash: metainfo.pieces[pieceIndex],
        expectedLength: thisPieceLength,
        pieceSegments: pieceSegments,
        handleFor: handleFor,
      );
      if (ok) {
        bitfield.setBit(pieceIndex, true);
        verified++;
      }
    }
  } finally {
    for (final raf in openFiles.values) {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  return RecheckResult(bitfield, verified, piecesNum);
}

/// Global byte-range layout for one torrent file.
class _FileLayout {
  final String filePath;
  final int offset;
  final int length;
  _FileLayout(this.filePath, this.offset, this.length);
}

/// Hash the bytes backing one piece across its (one or more) file segments and
/// compare to [expectedHash]. Returns false on any missing/short file or on a
/// SHA1 mismatch.
Future<bool> _verifyPiece({
  required String expectedHash,
  required int expectedLength,
  required List<_PieceFileSegment> pieceSegments,
  required Future<RandomAccessFile?> Function(String) handleFor,
}) async {
  // A piece must be fully backed by file segments; the downloader only maps
  // files that exist in the torrent, so a gap means a short/absent file.
  var covered = 0;
  for (final s in pieceSegments) {
    covered += s.length;
  }
  if (covered != expectedLength) return false;

  final digestSink = _DigestSink();
  final hasher = sha1.startChunkedConversion(digestSink);
  try {
    for (final seg in pieceSegments) {
      final raf = await handleFor(seg.filePath);
      if (raf == null) return false; // file missing
      await raf.setPosition(seg.fileOffset);
      var remaining = seg.length;
      while (remaining > 0) {
        final want =
            remaining < _readChunkSize ? remaining : _readChunkSize;
        final chunk = await raf.read(want);
        if (chunk.isEmpty) return false; // file shorter than expected
        hasher.add(chunk);
        remaining -= chunk.length;
        if (chunk.length < want && remaining > 0) {
          // Short read with bytes still owed: treat as truncated file.
          return false;
        }
      }
    }
  } finally {
    hasher.close();
  }

  final actual = digestSink.value;
  if (actual == null) return false;
  return _bytesToHex(actual.bytes) == expectedHash;
}

/// Collects the single [Digest] emitted by a chunked SHA1 conversion.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

String _bytesToHex(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
