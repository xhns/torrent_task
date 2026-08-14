import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path_pkg;
import 'package:torrent_model/torrent_model.dart';

/// Сколько байт читаем с диска за одну операцию ввода-вывода при хэшировании.
///
/// Кусок может весить мегабайты (у книг на 3 ГБ — до 4 МБ), поэтому читаем
/// порциями: пик потребления памяти ограничен этой константой, а не размером
/// куска.
const readChunkSize = 1 << 16; // 64 KiB

/// Кусок торрента, отображённый на срез одного файла на диске.
class PieceFileSegment {
  /// Абсолютный путь файла.
  final String filePath;

  /// Смещение внутри файла, с которого начинается срез.
  final int fileOffset;

  /// Сколько байт куска покрывает этот файл.
  final int length;

  const PieceFileSegment(this.filePath, this.fileOffset, this.length);
}

/// Раскладка одного файла торрента в глобальном байтовом пространстве.
class _FileLayout {
  final String filePath;
  final int offset;
  final int length;
  const _FileLayout(this.filePath, this.offset, this.length);
}

/// Плоское описание «как куски торрента лежат в файлах на диске».
///
/// Содержит только примитивы и списки примитивов — объект целиком пересылается
/// в изолят-хэшер (см. `piece_verifier.dart`), поэтому тащить сюда [Torrent]
/// (с его картой bencode и буферами) нельзя.
///
/// Единственный источник правды об отображении «кусок → срезы файлов»: им
/// пользуются и стартовый recheck ([verifyExistingFiles]), и рантайм-проверка
/// каждого докачанного куска. Разъезд этих двух отображений означал бы, что
/// recheck и загрузка считают хэш по разным байтам.
class TorrentDiskLayout {
  final int pieceLength;

  final int lastPieceLength;

  /// SHA1 каждого куска в hex, как в `metainfo.pieces`.
  final List<String> pieceHashes;

  final List<_FileLayout> _files;

  TorrentDiskLayout(
      this.pieceLength, this.lastPieceLength, this.pieceHashes, this._files);

  /// Собрать раскладку для [metainfo], файлы которого лежат в [downloadDir].
  ///
  /// Путь файла тот же, что использует `DownloadFileManager`:
  /// `join(downloadDir, file.path)`, где `file.path` уже начинается с имени
  /// торрента.
  factory TorrentDiskLayout.of(Torrent metainfo, String downloadDir) {
    final files = <_FileLayout>[];
    for (final f in metainfo.files) {
      files.add(_FileLayout(
          path_pkg.join(downloadDir, f.path), f.offset, f.length));
    }
    return TorrentDiskLayout(
      metainfo.pieceLength!,
      metainfo.lastPriceLength!,
      List<String>.from(metainfo.pieces),
      files,
    );
  }

  int get piecesCount => pieceHashes.length;

  /// Настоящая длина куска [pieceIndex]: последний кусок почти всегда короче.
  int pieceLengthAt(int pieceIndex) =>
      pieceIndex == piecesCount - 1 ? lastPieceLength : pieceLength;

  /// Срезы файлов, покрывающие кусок [pieceIndex], в порядке файлов торрента.
  ///
  /// Порядок обязан быть именно файловым: кусок на стыке склеивается из хвоста
  /// одного файла и головы следующего, и перестановка даёт другой хэш (ровно
  /// этот дефект был на стороне сида, см. `DownloadFileManager.readFile`).
  List<PieceFileSegment> segmentsFor(int pieceIndex) {
    final thisPieceLength = pieceLengthAt(pieceIndex);
    final pieceStart = pieceIndex * pieceLength;
    final pieceEnd = pieceStart + thisPieceLength;
    final segments = <PieceFileSegment>[];
    for (final layout in _files) {
      final fileStart = layout.offset;
      final fileEnd = layout.offset + layout.length;
      final overlapStart = pieceStart > fileStart ? pieceStart : fileStart;
      final overlapEnd = pieceEnd < fileEnd ? pieceEnd : fileEnd;
      if (overlapEnd <= overlapStart) continue;
      segments.add(PieceFileSegment(
        layout.filePath,
        overlapStart - fileStart,
        overlapEnd - overlapStart,
      ));
    }
    return segments;
  }
}

/// Диапазон кусков `[first, last]`, покрывающих байты файла с длиной [length],
/// начинающегося в глобальном смещении [offset]. Для пустого файла возвращает
/// `null` (покрывать нечего).
///
/// Тот же расчёт, что делает `DownloadFileManager._initFileMap`, но без
/// зависимости от списка `DownloadFile`: считается прямо по байтовой раскладке
/// торрента.
({int first, int last})? pieceRangeOfFile(
    {required int offset, required int length, required int pieceLength}) {
  if (length <= 0 || pieceLength <= 0) return null;
  final first = offset ~/ pieceLength;
  final last = (offset + length - 1) ~/ pieceLength;
  return (first: first, last: last);
}

/// Пути файлов [metainfo] (относительные, как в торренте), КАЖДЫЙ кусок
/// которых подтверждён локально: [have] отвечает по индексу куска.
///
/// Это единственный честный ответ на вопрос «этот файл дочитан до последнего
/// байта»: событие `DownloadFileManager.onFileComplete` про кусок на стыке
/// файлов знает только у ОДНОГО из соседей (кусок приписывается первому из
/// них), а про файлы, поднятые recheck'ом, не стреляет вовсе.
///
/// Файлы нулевой длины считаются готовыми: покрывать в них нечего.
Set<String> completedFilesOf(
    Torrent metainfo, bool Function(int pieceIndex) have) {
  final pieceLength = metainfo.pieceLength;
  if (pieceLength == null || pieceLength <= 0) return const {};
  final piecesCount = metainfo.pieces.length;
  final done = <String>{};
  for (final f in metainfo.files) {
    final range = pieceRangeOfFile(
        offset: f.offset, length: f.length, pieceLength: pieceLength);
    if (range == null) {
      done.add(f.path);
      continue;
    }
    var complete = true;
    for (var i = range.first; i <= range.last; i++) {
      // Индекс за пределами торрента — раскладка не сходится; файл готовым не
      // считаем (лучше недосказать, чем отдать на воспроизведение дыру).
      if (i < 0 || i >= piecesCount || !have(i)) {
        complete = false;
        break;
      }
    }
    if (complete) done.add(f.path);
  }
  return done;
}

/// Кэш read-хэндлов по пути файла: многофайловый торрент не должен открывать
/// один и тот же файл на каждый кусок.
///
/// Открывает только на чтение и ничего не создаёт: отсутствующий файл — это
/// `null` и «кусок не сошёлся», а не побочный эффект на диске.
class ReadHandleCache {
  final Map<String, RandomAccessFile?> _open = {};

  Future<RandomAccessFile?> handleFor(String filePath) async {
    if (_open.containsKey(filePath)) return _open[filePath];
    RandomAccessFile? raf;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        raf = await file.open(mode: FileMode.read);
      }
    } catch (_) {
      raf = null;
    }
    _open[filePath] = raf;
    return raf;
  }

  Future<void> close() async {
    for (final raf in _open.values) {
      try {
        await raf?.close();
      } catch (_) {}
    }
    _open.clear();
  }
}

/// Прочитать кусок [pieceIndex] с диска и сверить его SHA1 с
/// `layout.pieceHashes[pieceIndex]`.
///
/// `false` — отсутствующий/короткий файл, ошибка чтения или несовпадение хэша.
/// Функция ничего не пишет на диск.
Future<bool> verifyPieceOnDisk(TorrentDiskLayout layout, int pieceIndex,
    Future<RandomAccessFile?> Function(String) handleFor) async {
  final actual = await hashPieceOnDisk(layout, pieceIndex, handleFor);
  if (actual == null) return false;
  return actual == layout.pieceHashes[pieceIndex];
}

/// Посчитать SHA1 куска [pieceIndex] по его байтам на диске.
///
/// Возвращает hex-строку либо `null`, если байт на диске столько нет (файл
/// отсутствует, обрезан или не покрывает кусок целиком).
Future<String?> hashPieceOnDisk(TorrentDiskLayout layout, int pieceIndex,
    Future<RandomAccessFile?> Function(String) handleFor) async {
  final expectedLength = layout.pieceLengthAt(pieceIndex);
  final segments = layout.segmentsFor(pieceIndex);

  // Кусок обязан быть покрыт срезами файлов целиком: дыра означает, что торрент
  // описывает байты, которых на диске нет.
  var covered = 0;
  for (final s in segments) {
    covered += s.length;
  }
  if (covered != expectedLength) return null;

  final digestSink = _DigestSink();
  final hasher = sha1.startChunkedConversion(digestSink);
  try {
    for (final seg in segments) {
      final raf = await handleFor(seg.filePath);
      if (raf == null) return null; // файла нет
      await raf.setPosition(seg.fileOffset);
      var remaining = seg.length;
      while (remaining > 0) {
        final want = remaining < readChunkSize ? remaining : readChunkSize;
        final chunk = await raf.read(want);
        if (chunk.isEmpty) return null; // файл короче ожидаемого
        hasher.add(chunk);
        remaining -= chunk.length;
        if (chunk.length < want && remaining > 0) {
          // Короткое чтение с непрочитанным остатком — обрезанный файл.
          return null;
        }
      }
    }
  } finally {
    hasher.close();
  }

  final actual = digestSink.value;
  if (actual == null) return null;
  return bytesToHex(actual.bytes);
}

/// Забирает единственный [Digest] из чанкового SHA1.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

String bytesToHex(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
