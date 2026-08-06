// ВРЕМЕННЫЙ стенд: настоящая TorrentTask-раздача с пробросом порта.
import 'dart:io';
import 'package:torrent_task/torrent_task.dart';
import '../test/seeding_support.dart';

void log(String m) => print('[${DateTime.now().toIso8601String().substring(11, 19)}] $m');

void main() async {
  final tmp = await Directory.systemTemp.createTemp('livesd_');
  final files = [MapEntry('book.mp3', pseudoBytes(64 * 1024, 3))];
  final model = buildTorrent(
      name: 'live-book', pieceLength: 16 * 1024, files: files, infoHashSeed: 123);
  await writeFiles(tmp, model, files);

  final task = TorrentTask.newTask(model, tmp.path, listenPort: 51413);
  log('recheck: ${await task.recheck()} кусков');
  task.onReachability((r) => log('reachability changed -> $r'));
  final map = await task.start();
  log('start: tcp=${map['tcp_socket']} utp=${map['utp_socket']}');

  for (var i = 0; i < 30; i++) {
    await Future.delayed(const Duration(seconds: 4));
    final r = task.reachability;
    log('${r.toJson()}');
    if (i == 2) log('>>> ЖДУ ВНЕШНЕЕ ПОДКЛЮЧЕНИЕ на ${r.externalEndpoint}');
  }
  log('останавливаю задачу...');
  final sw = Stopwatch()..start();
  await task.stop();
  log('остановлена за ${sw.elapsed}');
  await tmp.delete(recursive: true);
  exit(0);
}
