// Стенд качающего: скачать торрент у заданного пира и рассказать, что при этом
// произошло — скорость, брак рантайм-проверки SHA1, баны источников,
// завершение задачи.
//
// Парный к tool/seed_spike.dart. Пиры задаются напрямую (--peer), трекер/DHT в
// этом сценарии не нужны: проверяем передачу и проверку данных, а не поиск
// источников.
//
// Запуск:
//   dart tool/leech_spike.dart <torrentFile> <savePath> --peer host:port \
//       [--peer host:port] [--seconds N] [--no-recheck-at-end]
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
    stderr.writeln(
        'usage: leech_spike.dart <torrent> <savePath> --peer host:port '
        '[--seconds N]');
    exit(64);
  }
  final torrentFile = args[0];
  final savePath = args[1];
  var seconds = 600;
  var recheckAtEnd = true;
  final directPeers = <CompactAddress>[];
  for (var i = 2; i < args.length; i++) {
    if (args[i] == '--seconds' && i + 1 < args.length) {
      seconds = int.parse(args[i + 1]);
    }
    if (args[i] == '--no-recheck-at-end') recheckAtEnd = false;
    if (args[i] == '--peer' && i + 1 < args.length) {
      final parts = args[i + 1].split(':');
      directPeers
          .add(CompactAddress(InternetAddress(parts[0]), int.parse(parts[1])));
    }
  }

  final model = await Torrent.parse(torrentFile);
  log('torrent   : ${model.name}');
  log('length    : ${model.length} bytes, pieces=${model.pieces.length} '
      'pieceLength=${model.pieceLength}');

  final task = TorrentTask.newTask(model, savePath);
  final verified = await task.recheck();
  log('recheck   : $verified / ${model.pieces.length} кусков уже на диске');

  final startedAt = DateTime.now();
  var completeAt = -1;
  task.onTaskComplete(() {
    completeAt = DateTime.now().difference(startedAt).inMilliseconds;
    log('EVENT onTaskComplete через ${completeAt}ms, progress=${task.progress}');
  });

  final map = await task.start();
  log('start()   : port=${map['tcp_socket']} downloaded=${map['downloaded']}');
  for (final p in directPeers) {
    log('PEER -> $p');
    task.addPeer(p);
  }

  var lastDownloaded = 0;
  var stallTicks = 0;
  final timer = Timer.periodic(const Duration(seconds: 2), (_) {
    final d = task.downloaded ?? 0;
    final delta = d - lastDownloaded;
    lastDownloaded = d;
    if (delta == 0) {
      stallTicks++;
    } else {
      stallTicks = 0;
    }
    log('progress=${(task.progress * 100).toStringAsFixed(2)}% '
        'downloaded=${(d / 1024 / 1024).toStringAsFixed(2)}MiB '
        '(+${(delta / 1024).toStringAsFixed(0)}KiB/2s) '
        'speed=${(task.currentDownloadSpeed * 1000 / 1024).toStringAsFixed(1)}KiB/s '
        'peers=${task.connectedPeersNumber}/${task.allPeersNumber} '
        'брак=${task.corruptedPiecesCount} '
        'бан=${task.bannedPeerIds.length}'
        '${stallTicks > 0 ? " (простой ${stallTicks * 2}с)" : ""}');
  });

  Future<void> finish() async {
    timer.cancel();
    log('=== ИТОГ ===');
    log('прогресс           : ${task.progress}');
    log('скачано            : ${task.downloaded} / ${model.length}');
    log('onTaskComplete     : '
        '${completeAt < 0 ? "НЕ ВЫЗЫВАЛСЯ" : "через ${completeAt}ms"}');
    log('брак SHA1 (кусков) : ${task.corruptedPiecesCount}');
    log('отключено пиров    : ${task.bannedPeerIds.length}');
    log('средняя скорость   : '
        '${(task.averageDownloadSpeed * 1000 / 1024).toStringAsFixed(1)} KiB/s');
    final wall = DateTime.now().difference(startedAt).inMilliseconds;
    log('время под нагрузкой: ${wall}ms');
    await task.stop();
    if (recheckAtEnd) {
      // Независимая сверка того, что реально лежит на диске.
      final control = TorrentTask.newTask(model, savePath);
      final ok = await control.recheck();
      log('КОНТРОЛЬНЫЙ RECHECK: $ok / ${model.pieces.length} кусков сошлись');
    }
    exit(0);
  }

  Timer(Duration(seconds: seconds), finish);
  task.onTaskComplete(() {
    // Дать хвостам дописаться и завершиться.
    Timer(const Duration(seconds: 5), finish);
  });
}
