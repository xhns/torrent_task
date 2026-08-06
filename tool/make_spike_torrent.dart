// Spike-only helper: build a .torrent for the seeding experiment using our own
// createTorrentBytes (the same path the audiobooks app uses when a user
// publishes a book).
//
// Usage:
//   dart tool/make_spike_torrent.dart <rootDir> <outFile> <announceUrl>...
import 'dart:io';

import 'package:torrent_model/torrent_model.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
        'usage: make_spike_torrent.dart <rootDir> <out.torrent> <announce>...');
    exit(64);
  }
  final rootDir = args[0];
  final outFile = args[1];
  final announces = args.sublist(2);

  final files = Directory(rootDir)
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.mp3'))
      .toList()
    ..sort();

  print('root: $rootDir');
  print('files (in torrent order): $files');

  final bytes = await createTorrentBytes(CreateTorrentSpec(
    rootDirPath: rootDir,
    relativeFilePaths: files,
    name: 'seed-spike-book',
    // One tier holding every tracker: BEP 12 lets a client stop after the
    // first *tier* that works, so separate tiers would mean aria2c only ever
    // talks to the first tracker.
    announceList: <List<String>>[announces],
    comment: 'seeding capability spike',
    createdBy: 'seed-spike',
  ));

  await File(outFile).writeAsBytes(bytes);
  print('wrote $outFile (${bytes.length} bytes)');

  final model = await Torrent.parse(outFile);
  print('name        : ${model.name}');
  print('infohash    : ${model.infoHash}');
  print('length      : ${model.length}');
  print('pieceLength : ${model.pieceLength}');
  print('pieces      : ${model.pieces.length}');
  print('announces   : ${model.announces}');
}
