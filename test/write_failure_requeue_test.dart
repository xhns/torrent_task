import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_task/torrent_task.dart';
import 'package:torrent_task/src/piece/base_piece_selector.dart';

/// Провал записи под-piece на диск не должен «съедать» его навсегда.
///
/// Баг: `Piece.subPieceDownloadComplete` перекладывает под-piece из очереди
/// докачки в `_writtingSubPieces`, а сеть подтверждает запрос ещё ДО записи.
/// Если запись потом провалилась и об этом никто не узнал, под-piece оставался
/// в `_writtingSubPieces` вечно: очередь пуста, `isCompleted` недостижим,
/// перезапросить некому — загрузка замирала на ~99% до ручной паузы+recheck.
void main() {
  group('Piece.subPieceWriteFailed', () {
    /// Piece на 4 под-piece'а (DEFAULT_REQUEST_LENGTH каждый).
    Piece newPiece() => Piece('hash', 0, DEFAULT_REQUEST_LENGTH * 4);

    test('возвращает под-piece из «пишущихся» обратно в очередь докачки', () {
      final piece = newPiece();
      final begin = DEFAULT_REQUEST_LENGTH * 2;

      // ПРЕДУСЛОВИЕ бага: под-piece ушёл из очереди в «пишущиеся».
      expect(piece.subPieceDownloadComplete(begin), isTrue);
      expect(piece.writtingSubPiecesCount, 1,
          reason: 'предусловие: под-piece должен «писаться»');
      expect(piece.containsSubpiece(2), isFalse,
          reason: 'предусловие: в очереди докачки его уже нет');

      expect(piece.subPieceWriteFailed(begin), isTrue);

      expect(piece.writtingSubPiecesCount, 0);
      expect(piece.containsSubpiece(2), isTrue,
          reason: 'под-piece обязан вернуться в очередь докачки');
      expect(piece.haveAvalidateSubPiece(), isTrue);
    });

    test('вернувшийся под-piece снова выдаётся на скачивание и piece '
        'в итоге завершается', () {
      final piece = newPiece();

      // Качаем все 4 под-piece'а; запись третьего (begin=2) проваливается.
      for (var i = 0; i < 4; i++) {
        final begin = i * DEFAULT_REQUEST_LENGTH;
        piece.subPieceDownloadComplete(begin);
        if (i == 2) {
          piece.subPieceWriteFailed(begin);
        } else {
          piece.subPieceWriteComplete(begin);
        }
      }

      // Без фикса здесь тупик: очередь пуста и piece никогда не завершится.
      expect(piece.isCompleted, isFalse);
      expect(piece.haveAvalidateSubPiece(), isTrue,
          reason: 'провалившийся под-piece снова доступен для запроса');
      expect(piece.popSubPiece(), 2);

      // Перезапросили, на этот раз записалось.
      piece.subPieceDownloadComplete(DEFAULT_REQUEST_LENGTH * 2);
      piece.subPieceWriteComplete(DEFAULT_REQUEST_LENGTH * 2);
      expect(piece.isCompleted, isTrue);
    });

    test('не воскрешает под-piece, который уже успешно записан', () {
      final piece = newPiece();
      final begin = DEFAULT_REQUEST_LENGTH;
      piece.subPieceDownloadComplete(begin);
      piece.subPieceWriteComplete(begin);

      // Поздний/дублирующий failed по уже закрытому блоку игнорируется.
      expect(piece.subPieceWriteFailed(begin), isFalse);
      expect(piece.containsSubpiece(1), isFalse);
      expect(piece.downloadedSubPiecesCount, 1);
    });

    test('failed по под-piece, который не «пишется», ничего не меняет', () {
      final piece = newPiece();
      final before = piece.avalidateSubPieceCount;
      expect(piece.subPieceWriteFailed(DEFAULT_REQUEST_LENGTH * 3), isFalse);
      expect(piece.avalidateSubPieceCount, before);
    });
  });

  group('PieceManager.processSubPieceWriteFailed', () {
    test('возвращает под-piece в очередь у нужного piece', () {
      final metaInfo = _buildTorrent(
        name: 'book',
        pieceLength: DEFAULT_REQUEST_LENGTH * 4,
        files: [MapEntry('a.mp3', List.filled(DEFAULT_REQUEST_LENGTH * 8, 7))],
      );
      final bitfield = Bitfield.createEmptyBitfield(metaInfo.pieces.length);
      final pm = PieceManager.createPieceManager(
          BasePieceSelector(), metaInfo, bitfield,
          verifier: null);

      final piece = pm[1]!;
      piece.subPieceDownloadComplete(DEFAULT_REQUEST_LENGTH);
      expect(piece.writtingSubPiecesCount, 1, reason: 'предусловие');

      expect(
          pm.processSubPieceWriteFailed(1, DEFAULT_REQUEST_LENGTH,
              DEFAULT_REQUEST_LENGTH),
          isTrue);
      expect(piece.containsSubpiece(1), isTrue);
    });

    test('неизвестный piece не роняет обработчик', () {
      final metaInfo = _buildTorrent(
        name: 'book',
        pieceLength: DEFAULT_REQUEST_LENGTH * 4,
        files: [MapEntry('a.mp3', List.filled(DEFAULT_REQUEST_LENGTH * 4, 7))],
      );
      final bitfield = Bitfield.createEmptyBitfield(metaInfo.pieces.length);
      final pm = PieceManager.createPieceManager(
          BasePieceSelector(), metaInfo, bitfield,
          verifier: null);
      expect(pm.processSubPieceWriteFailed(999, 0, DEFAULT_REQUEST_LENGTH),
          isFalse);
    });
  });

  group('DownloadFileManager.writeFile — событие провала', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('twf_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// Запись обязана провалиться: на месте целевого файла книги стоит КАТАЛОГ,
    /// поэтому открыть его на запись нельзя (`getRandomAccessFile` кидает).
    /// Это моделирует «файл недоступен для записи» — залочен антивирусом,
    /// отозваны права, недоступный путь.
    test('непишущийся файл даёт onSubPieceWriteFailed, а не тишину', () async {
      final content = List.filled(DEFAULT_REQUEST_LENGTH * 2, 3);
      final metaInfo = _buildTorrent(
        name: 'book',
        pieceLength: DEFAULT_REQUEST_LENGTH * 2,
        files: [MapEntry('a.mp3', content)],
      );

      // Занимаем путь файла каталогом — запись по нему невозможна.
      final blocking = Directory(p.join(tmp.path, 'book', 'a.mp3'));
      blocking.createSync(recursive: true);

      final stateFile = await StateFile.getStateFile(tmp.path, metaInfo);
      final fm = await DownloadFileManager.createFileManager(
          metaInfo, tmp.path, stateFile);
      addTearDown(() async {
        try {
          await fm.close();
        } catch (_) {}
      });

      final failed = <List<int>>[];
      final completed = <List<int>>[];
      fm.onSubPieceWriteFailed((i, b, l) => failed.add([i, b, l]));
      fm.onSubPieceWriteComplete((i, b, l) => completed.add([i, b, l]));

      fm.writeFile(0, 0, List.filled(DEFAULT_REQUEST_LENGTH, 3));

      // События летят через Timer.run — даём микротаскам/таймерам провернуться.
      await Future.delayed(const Duration(milliseconds: 300));

      expect(failed, isNotEmpty,
          reason: 'провал записи обязан быть сообщён наружу');
      expect(failed.first, [0, 0, DEFAULT_REQUEST_LENGTH]);
      expect(completed, isEmpty,
          reason: 'незаписанный блок не должен считаться записанным');
    });
  });
}

/// Собирает [Torrent] вручную из раскладки в памяти, считая настоящие SHA1
/// кусков (как в recheck_test.dart).
Torrent _buildTorrent({
  required String name,
  required int pieceLength,
  required List<MapEntry<String, List<int>>> files,
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
    hashes.add(_hex(sha1.convert(all.sublist(start, end)).bytes));
  }

  final infoHashBuffer = Uint8List.fromList(List<int>.generate(20, (i) => i));
  final torrent =
      Torrent(<String, dynamic>{}, name, _hex(infoHashBuffer), infoHashBuffer);

  var offset = 0;
  for (final f in files) {
    final fullPath = p.join(name, f.key);
    torrent.addFile(
        TorrentFile(p.basename(f.key), fullPath, f.value.length, offset));
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
  return torrent;
}

String _hex(List<int> bytes) {
  final b = StringBuffer();
  for (final x in bytes) {
    b.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}
