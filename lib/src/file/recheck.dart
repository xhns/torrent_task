import 'package:torrent_model/torrent_model.dart';

import '../peer/bitfield.dart';
import 'piece_layout.dart';

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
/// Pieces are read in [readChunkSize] chunks; a missing file, a file shorter
/// than required, or a SHA1 mismatch leaves the piece's bit unset. The last
/// (possibly short) piece is hashed at its true length ([Torrent.lastPriceLength]),
/// and pieces that span multiple files are reassembled across file boundaries.
///
/// The "piece -> file slices" mapping and the hashing itself live in
/// [TorrentDiskLayout] / [verifyPieceOnDisk] and are shared with the runtime
/// per-piece verification (`IsolatePieceVerifier`): recheck and the downloader
/// must never disagree about which bytes back a piece.
///
/// This function opens files read-only and closes every handle before
/// returning, even on error. It does not create, truncate, or otherwise mutate
/// any file on disk.
Future<RecheckResult> verifyExistingFiles(
    Torrent metainfo, String downloadDir) async {
  final layout = TorrentDiskLayout.of(metainfo, downloadDir);
  final piecesNum = layout.piecesCount;
  final bitfield = Bitfield.createEmptyBitfield(piecesNum);
  final handles = ReadHandleCache();

  var verified = 0;
  try {
    for (var pieceIndex = 0; pieceIndex < piecesNum; pieceIndex++) {
      final ok =
          await verifyPieceOnDisk(layout, pieceIndex, handles.handleFor);
      if (ok) {
        bitfield.setBit(pieceIndex, true);
        verified++;
      }
    }
  } finally {
    await handles.close();
  }

  return RecheckResult(bitfield, verified, piecesNum);
}
