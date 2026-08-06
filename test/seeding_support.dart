import 'dart:io';
import 'dart:typed_data';

import 'package:bencode_dart/bencode_dart.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:torrent_model/torrent_model.dart';

/// Общая обвязка для тестов раздачи: рукописный [Torrent] и заглушка
/// HTTP-трекера, которая записывает КАЖДЫЙ announce (событие, left, port).
///
/// Трекер настоящий по протоколу — тот же `HttpTracker` ходит к нему по сети
/// (loopback), поэтому тест проверяет реальный путь «задача → announce», а не
/// внутренние вызовы.

/// Один зафиксированный заглушкой announce.
class AnnounceHit {
  /// Значение query-параметра `event`; для периодического анонса BitTorrent
  /// допускает его отсутствие — тогда здесь пустая строка.
  final String event;
  final int left;
  final int port;
  final int uploaded;
  final DateTime at;

  AnnounceHit(this.event, this.left, this.port, this.uploaded, this.at);

  @override
  String toString() =>
      'AnnounceHit(event=$event, left=$left, port=$port, uploaded=$uploaded)';
}

/// Заглушка HTTP-трекера на loopback.
class StubTracker {
  final HttpServer _server;
  final List<AnnounceHit> hits = [];

  /// Пиры, которые трекер возвращает в compact-формате.
  final List<({InternetAddress address, int port})> peers = [];

  /// Интервал, который трекер сообщает клиенту (сек).
  int interval;

  StubTracker._(this._server, this.interval);

  static Future<StubTracker> start({int interval = 1800}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final t = StubTracker._(server, interval);
    server.listen(t._handle);
    return t;
  }

  Uri get announceUrl =>
      Uri.parse('http://127.0.0.1:${_server.port}/announce');

  List<AnnounceHit> hitsWithEvent(String event) =>
      hits.where((h) => h.event == event).toList();

  void _handle(HttpRequest request) {
    final q = request.uri.queryParameters;
    hits.add(AnnounceHit(
      q['event'] ?? '',
      int.tryParse(q['left'] ?? '') ?? -1,
      int.tryParse(q['port'] ?? '') ?? -1,
      int.tryParse(q['uploaded'] ?? '') ?? -1,
      DateTime.now(),
    ));

    final compact = <int>[];
    for (final peer in peers) {
      compact.addAll(peer.address.rawAddress);
      compact.add((peer.port >> 8) & 0xff);
      compact.add(peer.port & 0xff);
    }
    final body = encode(<String, dynamic>{
      'interval': interval,
      'complete': 1,
      'incomplete': 0,
      'peers': Uint8List.fromList(compact),
    }) as List<int>;

    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'plain')
      ..add(body);
    request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

String hex(List<int> bytes) {
  final b = StringBuffer();
  for (final x in bytes) {
    b.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// Собирает [Torrent] вручную (без разбора .torrent) с настоящими SHA1 по
/// содержимому, чтобы recheck/verify видели корректные хеши.
Torrent buildTorrent({
  required String name,
  required int pieceLength,
  required List<MapEntry<String, List<int>>> files,
  List<Uri> announces = const [],
  int infoHashSeed = 0,
}) {
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
    hashes.add(hex(sha1.convert(all.sublist(start, end)).bytes));
  }

  final infoHashBuffer =
      Uint8List.fromList(List<int>.generate(20, (i) => (i + infoHashSeed) & 0xff));
  final torrent =
      Torrent(<String, dynamic>{}, name, hex(infoHashBuffer), infoHashBuffer);

  var offset = 0;
  for (final f in files) {
    final fullPath = p.join(name, f.key);
    torrent
        .addFile(TorrentFile(p.basename(f.key), fullPath, f.value.length, offset));
    offset += f.value.length;
  }
  torrent.length = totalLength;
  torrent.pieceLength = pieceLength;
  var lastLen = totalLength % pieceLength;
  if (lastLen == 0) lastLen = pieceLength;
  torrent.lastPriceLength = lastLen;
  for (final h in hashes) {
    torrent.addPiece(h);
  }
  for (final a in announces) {
    torrent.addAnnounce(a);
  }
  return torrent;
}

Future<void> writeFiles(
    Directory dir, Torrent t, List<MapEntry<String, List<int>>> files) async {
  for (final entry in files) {
    final f = File(p.join(dir.path, t.name, entry.key));
    await f.create(recursive: true);
    await f.writeAsBytes(entry.value);
  }
}

/// Детерминированное «содержимое книги» — чтобы piece-хеши были осмысленными.
List<int> pseudoBytes(int length, int seed) {
  final out = Uint8List(length);
  var x = (seed * 2654435761) & 0xffffffff;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (x >> 16) & 0xff;
  }
  return out;
}
