## 0.0.1

- Initial version

## 0.0.2

- Fix license file error
- Fix example error

## 0.1.1
- Add DHT support
- Add PEX support
- Change Tracker
- Fix some bugs

## 0.1.2
- Support peer reconnect
- Fix some bugs

## 0.1.4
- Fix some issues
- Fix peer download slow issue

## 0.2.0
- Add UTP support
- Add holepunch extension
- Add LSD extension
- Fix PEX extension bugs

## 0.2.1
- Change congestion control

## 0.3.0
- Add Send Metadata extension (BEP0009)

## 0.4.0
- Modernize to Dart 3 (`sdk: '>=3.0.0 <4.0.0'`); clean up stale commented
  path-dependency lines and the malformed `bencode_dart :` key in `pubspec.yaml`.
- Declare the previously-implicit `path` dependency explicitly; mark the package
  `publish_to: none` (all dependencies are local path deps).
- Switch linting to `package:lints/recommended.yaml`; drop `pedantic`.
  `dart analyze --fatal-infos` is clean. SCREAMING_CASE protocol constants and
  the wire op-code identifiers are intentionally preserved (naming lints
  disabled in `analysis_options.yaml`).
- Bug fixes surfaced by the null-safety review (behaviour/protocol preserved):
  - `peer.dart` `_TCPPeer.connectRemote`: `throw TCPConnectException(e as
    TCPConnectException)` always raised a `TypeError` instead of the intended
    wrapper; now wraps the real connect failure.
  - `peer.dart` `_processCancel`: when a cancelled request was not in the
    buffer, an unassigned index removed the wrong entry (or threw); now removes
    only on a match.
  - `lsd.dart`: announce port upper bound was the typo `63354`; corrected to
    `65535`, so peers on ports 63355-65535 are no longer dropped. Also guard a
    missing `Infohash:` field.
  - `base_piece_selector.dart`: returns `null` when no piece is downloadable
    instead of crashing on an unassigned variable.
  - `download_file.dart` `getRandomAccessFile`: throws `ArgumentError` on an
    unknown access type instead of returning `null` from a non-nullable Future;
    `delete()` no longer `return`s inside a `finally` (which swallowed errors).
  - `metadata_downloader.dart`: guard a missing bencode terminator and fix an
    off-by-one `data[i + 1]` read at the end of the buffer.
  - `peers_manager.dart` `disposeAllSeeder`: iterate a snapshot to avoid
    concurrent-modification while `dispose()` mutates the active-peer set.
- Replace the symbolic tests with a real unit suite (22 tests): bitfield logic,
  peer-id/hex utils, BEP9 metadata and PEX bencode round-trips, piece-selector
  logic, and a loopback-TCP peer wire round-trip (handshake, choke/unchoke,
  interested, have, bitfield, request, port). Network/swarm/tracker/DHT paths
  are not exercised in CI.
- Add a GitHub Actions CI workflow (clones the six sibling path deps from the
  `chore/modernize-dart3` branch, then `dart pub get` / `analyze` / `test`).
## 0.4.1

- **Behavior change — rarest-first piece selection.** `BasePieceSelector`
  previously only performed rarest-first when called with `random == true`
  (the very first selection of a session). In the steady-state `random == false`
  path it returned the *first* candidate piece that happened to beat the
  initial candidate, not the globally rarest one — effectively near-sequential
  selection. It now always selects the candidate with the fewest available
  peers (true rarest-first, the standard BitTorrent strategy), breaking ties on
  fewest remaining sub pieces, then — only when `random == true` — randomly
  among fully-tied candidates (deterministic first-tie otherwise). This changes
  which pieces a downloading client requests and the order it requests them,
  improving copy distribution / swarm health. The public `PieceSelector`
  interface is unchanged.
- Add unit tests for the selector: rarest piece chosen regardless of list
  position, peer-count ties broken by sub-piece count, full ties
  (deterministic vs. random), unavailable pieces skipped, and empty set → null.

## 0.5.0

- **Feature — force re-verify (recheck).** Add the standard BitTorrent
  "force re-check": verify the files already present on disk against the
  torrent's per-piece SHA1 hashes and rebuild the local bitfield, so a fresh
  task pointed at a folder of previously downloaded files (with no
  `<infohash>.bt.state`) recognises complete books as complete/seeding and
  resumes partial ones from the right offset instead of re-downloading
  everything.
  - New `TorrentTask.recheck()` → `Future<int>` (returns the number of verified
    pieces). It lazily creates the `StateFile`, verifies on-disk files and
    persists the reconciled bitfield. Intended to be called **before**
    `start()`; the existing happy path is unchanged when it is not called.
  - New standalone `verifyExistingFiles(Torrent metainfo, String downloadDir)`
    → `Future<RecheckResult>` for callers that just want the reconstructed
    bitfield without a task. Exported from `package:torrent_task/torrent_task.dart`.
  - Each piece is read from disk in bounded 64 KiB chunks (no whole-file/whole-
    piece buffering) and SHA1-hashed; the last (short) piece is hashed at
    `lastPriceLength`, and pieces straddling file boundaries are reassembled
    across files. Missing, short, or corrupt files leave their pieces unset.
    Read handles are opened read-only and always closed; no file is created or
    mutated.
- Add `crypto` as a direct dependency (used for piece SHA1 verification).
- Add tests covering: all-valid → complete, single corrupted piece, missing
  file, short last piece (valid + corrupt), multi-file straddling piece (both
  present + one missing), empty dir, and the `TorrentTask.recheck()`
  integration with persistence across a reopened `StateFile`.
