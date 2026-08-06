// Spike-only seeding harness.
//
// Loads a .torrent whose files are already complete on disk, verifies them,
// starts TorrentTask as a pure seeder and logs, verbosely, everything that
// matters for answering "can we actually upload to a stranger?":
//   - the listening TCP port we advertise
//   - every peer address we learn about and from which source
//   - connect/disconnect of peers
//   - uploaded byte counter and upload speed
//
// Usage:
//   dart tool/seed_spike.dart <torrentFile> <savePath> [--no-dht] [--seconds N]
//       [--port N] [--no-mapping] [--no-utp]
import 'dart:async';
import 'dart:io';

import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_task/torrent_task.dart';

String _ts() {
  final n = DateTime.now();
  return '${n.hour.toString().padLeft(2, '0')}:'
      '${n.minute.toString().padLeft(2, '0')}:'
      '${n.second.toString().padLeft(2, '0')}.'
      '${n.millisecond.toString().padLeft(3, '0')}';
}

void log(String msg) => print('[${_ts()}] $msg');

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: seed_spike.dart <torrent> <savePath> '
        '[--seconds N] [--port N] [--no-mapping] [--no-utp]');
    exit(64);
  }
  final torrentFile = args[0];
  final savePath = args[1];
  var seconds = 300;
  // Workaround for the pure-seeder announce hole: TorrentTask.start() only
  // calls _tracker.complete() when the torrent is already complete, and
  // TorrentAnnounceTracker.complete() iterates the *already created* tracker
  // map — which is empty, because only runTracker() ever populates it. So a
  // seeder never announces at all. --force-announce re-adds the announce via
  // the public startAnnounceUrl(), which does go through runTracker().
  var forceAnnounce = false;
  // Слушающий порт и автопроброс — параметры стенда: два стенда на одной
  // машине обязаны разъехаться по портам, а прогон в чужой сети не должен
  // молча ставить маппинг на чужой роутер.
  var listenPort = kDefaultListenPort;
  var mapping = true;
  var enableUtp = true;
  final extraTrackers = <Uri>[];
  final directPeers = <CompactAddress>[];
  for (var i = 2; i < args.length; i++) {
    if (args[i] == '--seconds' && i + 1 < args.length) {
      seconds = int.parse(args[i + 1]);
    }
    if (args[i] == '--port' && i + 1 < args.length) {
      listenPort = int.parse(args[i + 1]);
    }
    if (args[i] == '--no-mapping') mapping = false;
    if (args[i] == '--no-utp') enableUtp = false;
    if (args[i] == '--force-announce') forceAnnounce = true;
    if (args[i] == '--extra-tracker' && i + 1 < args.length) {
      extraTrackers.add(Uri.parse(args[i + 1]));
    }
    // Hand the seeder a peer address directly, bypassing tracker/DHT/LSD
    // discovery entirely. This isolates "can we upload at all, over an
    // outbound connection we initiate" from "can we be discovered".
    if (args[i] == '--peer' && i + 1 < args.length) {
      final parts = args[i + 1].split(':');
      directPeers.add(CompactAddress(
          InternetAddress(parts[0]), int.parse(parts[1])));
    }
  }

  final model = await Torrent.parse(torrentFile);
  log('torrent   : ${model.name}');
  log('infohash  : ${model.infoHash}');
  log('length    : ${model.length} bytes, pieces=${model.pieces.length} '
      'pieceLength=${model.pieceLength}');
  log('announces : ${model.announces}');

  final task = TorrentTask.newTask(model, savePath,
      listenPort: listenPort, enableUtp: enableUtp, enablePortMapping: mapping);

  log('--- recheck: verifying files already on disk ---');
  final verified = await task.recheck();
  log('recheck   : $verified / ${model.pieces.length} pieces verified');
  if (verified != model.pieces.length) {
    log('!! WARNING: not a complete seed — only $verified pieces present');
  }

  task.onTaskComplete(() => log('EVENT onTaskComplete'));
  task.onStop(() => log('EVENT onStop'));

  final startedAt = DateTime.now();
  final map = await task.start();
  log('start()   : name=${map['name']} downloaded=${map['downloaded']} '
      'uploaded=${map['uploaded']} total=${map['total_length']} '
      'pieces=${map['total_pieces_num']}');
  log('LISTENING TCP PORT = ${map['tcp_socket']}   <-- advertised to tracker/DHT/LSD');

  if (forceAnnounce) {
    for (final a in model.announces) {
      log('FORCE ANNOUNCE -> $a');
      task.startAnnounceUrl(a, model.infoHashBuffer!);
    }
  } else {
    log('(stock behaviour: relying on TorrentTask.start() to announce)');
  }
  for (final a in extraTrackers) {
    log('EXTRA ANNOUNCE -> $a');
    task.startAnnounceUrl(a, model.infoHashBuffer!);
  }
  for (final p in directPeers) {
    log('DIRECT PEER (outbound connect from us) -> $p');
    task.addPeer(p);
  }

  var lastUploaded = 0;
  var firstByteAt = -1;
  var lastPeerLine = '';

  final timer = Timer.periodic(const Duration(seconds: 2), (_) {
    final up = task.uploaded ?? 0;
    final active = task.connectedPeersNumber;
    final seeders = task.seederNumber;
    final all = task.allPeersNumber;

    if (up > 0 && firstByteAt < 0) {
      firstByteAt = DateTime.now().difference(startedAt).inMilliseconds;
      log('*** FIRST UPLOADED BYTES after ${firstByteAt}ms ***');
    }

    final line = 'peers(active/seeder/known)=$active/$seeders/$all';
    if (line != lastPeerLine) {
      log('PEERS CHANGED -> $line');
      lastPeerLine = line;
    }

    final delta = up - lastUploaded;
    lastUploaded = up;
    log('uploaded=${(up / 1024 / 1024).toStringAsFixed(2)}MiB '
        '(+${(delta / 1024).toStringAsFixed(0)}KiB/2s) '
        'upSpeed=${(task.uploadSpeed * 1000 / 1024).toStringAsFixed(1)}KiB/s '
        'avgUp=${(task.averageUploadSpeed * 1000 / 1024).toStringAsFixed(1)}KiB/s '
        '$line');
  });

  Timer(Duration(seconds: seconds), () async {
    timer.cancel();
    log('=== SUMMARY ===');
    log('total uploaded : ${task.uploaded} bytes '
        '(${((task.uploaded ?? 0) / 1024 / 1024).toStringAsFixed(2)} MiB)');
    log('time to first byte : '
        '${firstByteAt < 0 ? "NEVER UPLOADED" : "${firstByteAt}ms"}');
    log('peers seen     : ${task.allPeersNumber}');
    await task.stop();
    exit(0);
  });
}
