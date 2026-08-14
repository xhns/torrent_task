import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_task/torrent_task.dart';
import 'package:torrent_task/src/piece/base_piece_selector.dart';

/// Режим «слушать по мере скачивания»: куски выбираются по ПОРЯДКУ, а не по
/// редкости, и приложение может узнать, какие файлы уже дочитаны до последнего
/// байта.
void main() {
  group('SequentialPieceSelector', () {
    test('берёт кусок с минимальным индексом, а не самый редкий', () {
      final selector = SequentialPieceSelector();
      // p0 — самый распространённый (9 пиров), rarest-first взял бы p2.
      final p0 = _FakePiece(0, peers: 9, subPieces: 4);
      final p1 = _FakePiece(1, peers: 5, subPieces: 4);
      final p2 = _FakePiece(2, peers: 1, subPieces: 4);
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2});
      for (final random in [false, true]) {
        expect(selector.selectPiece('peerA', [2, 0, 1], provider, random),
            same(p0),
            reason: 'random=$random не должен влиять на порядок');
      }
      // Контраст: тот же расклад rarest-first'ом даёт самый редкий кусок.
      expect(BasePieceSelector().selectPiece('peerA', [2, 0, 1], provider),
          same(p2));
    });

    test('не берёт куски, недоступные у этого пира', () {
      final selector = SequentialPieceSelector();
      final p0 = _FakePiece(0, peers: 3, subPieces: 4, availableToPeer: false);
      final p1 = _FakePiece(1, peers: 3, subPieces: 4);
      final provider = _FakePieceProvider({0: p0, 1: p1});
      expect(selector.selectPiece('peerA', [0, 1], provider), same(p1));
    });

    test('не берёт куски без свободных под-кусков', () {
      final selector = SequentialPieceSelector();
      final p0 = _FakePiece(0, peers: 3, subPieces: 0); // весь роздан
      final p1 = _FakePiece(1, peers: 3, subPieces: 2);
      final provider = _FakePieceProvider({0: p0, 1: p1});
      expect(selector.selectPiece('peerA', [0, 1], provider), same(p1));
    });

    test('пустой список кандидатов → null', () {
      final selector = SequentialPieceSelector();
      final provider = _FakePieceProvider({});
      expect(selector.selectPiece('peerA', <int>[], provider), isNull);
      expect(selector.selectPiece('peerA', [0, 1], provider), isNull);
    });

    test('pieceOrder задаёт порядок ВОСПРОИЗВЕДЕНИЯ, а не индексов', () {
      // Первая глава книги лежит в конце торрента: её куски (4,5) обязаны
      // приехать раньше кусков 0..3.
      final selector = SequentialPieceSelector(pieceOrder: [4, 5, 0, 1, 2, 3]);
      final pieces = {
        for (var i = 0; i < 6; i++) i: _FakePiece(i, peers: 3, subPieces: 4)
      };
      final provider = _FakePieceProvider(pieces);
      expect(selector.selectPiece('peerA', [0, 1, 2, 3, 4, 5], provider),
          same(pieces[4]));
      // Кусок 4 разобран — следующий по очереди 5, а не 0.
      pieces[4] = _FakePiece(4, peers: 3, subPieces: 0);
      expect(
          selector.selectPiece(
              'peerA', [0, 1, 2, 3, 4, 5], _FakePieceProvider(pieces)),
          same(pieces[5]));
    });

    test('куски вне pieceOrder качаются после него, по возрастанию индекса',
        () {
      // В очередь попали только куски книги (2,3); обложка/описание (0,1) —
      // хвостом.
      final selector = SequentialPieceSelector(pieceOrder: [2, 3]);
      expect(selector.rankOf(2), lessThan(selector.rankOf(0)));
      expect(selector.rankOf(3), lessThan(selector.rankOf(0)));
      expect(selector.rankOf(0), lessThan(selector.rankOf(1)));

      final pieces = {
        for (var i = 0; i < 4; i++) i: _FakePiece(i, peers: 3, subPieces: 4)
      };
      final provider = _FakePieceProvider(pieces);
      expect(selector.selectPiece('peerA', [0, 1, 2, 3], provider),
          same(pieces[2]));
      // Остались только «хвостовые» куски — среди них меньший индекс.
      expect(selector.selectPiece('peerA', [1, 0], provider), same(pieces[0]));
    });

    test('повтор индекса в pieceOrder не сдвигает очередь', () {
      final selector = SequentialPieceSelector(pieceOrder: [5, 5, 4]);
      expect(selector.rankOf(5), 0);
      expect(selector.rankOf(4), 1);
    });
  });

  group('createPieceSelector', () {
    test('по умолчанию — rarest-first (поведение движка не меняется)', () {
      expect(createPieceSelector(), isA<BasePieceSelector>());
      expect(createPieceSelector(sequential: false), isA<BasePieceSelector>());
    });

    test('sequential:true — последовательный селектор с заданным порядком', () {
      final s = createPieceSelector(sequential: true, pieceOrder: [3, 0]);
      expect(s, isA<SequentialPieceSelector>());
      final seq = s as SequentialPieceSelector;
      expect(seq.rankOf(3), lessThan(seq.rankOf(0)));
    });
  });

  group('PieceManager + sequential', () {
    // Реальный PieceManager с реальными кусками: проверяем не селектор в
    // вакууме, а путь, которым ходит движок (эвристики менеджера поверх
    // селектора).
    PieceManager manager(PieceSelector selector, {int pieces = 4}) {
      final t = _torrent(
        pieceLength: 32 * 1024,
        files: [MapEntry('01.mp3', 32 * 1024 * pieces)],
      );
      final pm = PieceManager.createPieceManager(
          selector, t, Bitfield.createEmptyBitfield(t.pieces.length),
          verifier: null);
      for (var i = 0; i < pieces; i++) {
        pm[i]!.addAvalidatePeer('peerA');
      }
      return pm;
    }

    test('suggest-кусок пира НЕ обходит очередь в sequential', () {
      final pm = manager(SequentialPieceSelector());
      // ПРЕДУСЛОВИЕ: кусок 3 действительно доступен и был бы взят как suggest.
      expect(pm[3], isNotNull);
      final picked = pm.selectPiece('peerA', [0, 1, 2, 3], pm, {3});
      expect(picked!.index, 0,
          reason: 'следующий кусок — самый нужный, а не подсказанный пиром');
    });

    test('дефолт (rarest-first): suggest-кусок берётся как раньше', () {
      final pm = manager(BasePieceSelector());
      final picked = pm.selectPiece('peerA', [0, 1, 2, 3], pm, {3});
      expect(picked!.index, 3, reason: 'поведение ядра без sequential прежнее');
    });

    test('уже начатый кусок НЕ обходит очередь в sequential', () {
      final pm = manager(SequentialPieceSelector());
      // Кусок 2 уже качается: в дефолтном режиме менеджер сузил бы кандидатов
      // до него одного.
      pm.processDownloadingPiece(2);
      final picked = pm.selectPiece('peerA', [0, 1, 2, 3], pm, <int>{});
      expect(picked!.index, 0);
    });

    test('дефолт (rarest-first): уже начатый кусок предпочитается как раньше',
        () {
      final pm = manager(BasePieceSelector());
      pm.processDownloadingPiece(2);
      final picked = pm.selectPiece('peerA', [0, 1, 2, 3], pm, <int>{});
      expect(picked!.index, 2, reason: 'поведение ядра без sequential прежнее');
    });

    test('pieceOrder соблюдается и через менеджер', () {
      final pm = manager(SequentialPieceSelector(pieceOrder: [2, 3, 0, 1]));
      pm.processDownloadingPiece(1);
      expect(pm.selectPiece('peerA', [0, 1, 2, 3], pm, {0})!.index, 2);
    });
  });

  group('completedFilesOf', () {
    // Раскладка: pieceLength 10, три файла по 10/15/5 байт.
    // f1: байты 0..9    → кусок 0
    // f2: байты 10..24  → куски 1,2 (кусок 2 общий с f3)
    // f3: байты 25..29  → кусок 2
    final torrent = _torrent(pieceLength: 10, files: const [
      MapEntry('01.mp3', 10),
      MapEntry('02.mp3', 15),
      MapEntry('03.mp3', 5),
    ]);

    test('файл готов, когда готовы ВСЕ покрывающие его куски', () {
      expect(completedFilesOf(torrent, {0}.contains),
          {p.join('Книга', '01.mp3')});
      expect(completedFilesOf(torrent, {0, 1}.contains),
          {p.join('Книга', '01.mp3')},
          reason: 'второму файлу не хватает куска 2');
      expect(
          completedFilesOf(torrent, {0, 1, 2}.contains),
          {
            p.join('Книга', '01.mp3'),
            p.join('Книга', '02.mp3'),
            p.join('Книга', '03.mp3'),
          });
    });

    test('кусок на стыке засчитывается ОБОИМ соседям', () {
      // Кусок 2 покрывает хвост f2 и весь f3. Пока его нет — не готов ни один
      // из них, даже если «свои» куски на месте.
      expect(completedFilesOf(torrent, {1}.contains), isEmpty);
      // Есть только стыковой кусок — f3 целиком в нём, а f2 всё ещё нет.
      expect(completedFilesOf(torrent, {2}.contains),
          {p.join('Книга', '03.mp3')});
    });

    test('ничего не скачано → пусто', () {
      expect(completedFilesOf(torrent, (_) => false), isEmpty);
    });

    test('пустой файл считается готовым', () {
      final t = _torrent(pieceLength: 10, files: const [
        MapEntry('cover.jpg', 0),
        MapEntry('01.mp3', 10),
      ]);
      expect(completedFilesOf(t, (_) => false), {p.join('Книга', 'cover.jpg')});
    });
  });

  group('pieceRangeOfFile', () {
    test('файл внутри одного куска', () {
      expect(pieceRangeOfFile(offset: 2, length: 4, pieceLength: 10),
          (first: 0, last: 0));
    });

    test('файл, кончающийся ровно на границе куска', () {
      expect(pieceRangeOfFile(offset: 0, length: 20, pieceLength: 10),
          (first: 0, last: 1),
          reason: 'кусок 2 файлу уже не принадлежит');
    });

    test('пустой файл не покрывается кусками', () {
      expect(pieceRangeOfFile(offset: 10, length: 0, pieceLength: 10), isNull);
    });
  });
}

/// Минимальный [Torrent] по описанию «имя файла → длина». Хэши кусков здесь не
/// важны (проверяется раскладка, а не содержимое), поэтому кладём заглушки.
Torrent _torrent({
  required int pieceLength,
  required List<MapEntry<String, int>> files,
  String name = 'Книга',
}) {
  final infoHashBuffer = Uint8List.fromList(List<int>.generate(20, (i) => i));
  final t = Torrent(<String, dynamic>{}, name, 'hash', infoHashBuffer);
  var offset = 0;
  for (final f in files) {
    t.addFile(TorrentFile(f.key, p.join(name, f.key), f.value, offset));
    offset += f.value;
  }
  t.length = offset;
  t.pieceLength = pieceLength;
  var lastLen = offset % pieceLength;
  if (lastLen == 0) lastLen = pieceLength;
  t.lastPriceLength = lastLen;
  final piecesCount = (offset + pieceLength - 1) ~/ pieceLength;
  for (var i = 0; i < piecesCount; i++) {
    t.addPiece('piece$i');
  }
  return t;
}

class _FakePiece extends Piece {
  final int _peers;
  final int _subPieces;
  final bool _availableToPeer;

  _FakePiece(int index,
      {required int peers,
      required int subPieces,
      bool availableToPeer = true})
      : _peers = peers,
        _subPieces = subPieces,
        _availableToPeer = availableToPeer,
        super('hash$index', index, 16384, 16384);

  @override
  int get avalidatePeersCount => _peers;

  @override
  int get avalidateSubPieceCount => _subPieces;

  @override
  bool haveAvalidateSubPiece() => _subPieces > 0;

  @override
  bool containsAvalidatePeer(String id) => _availableToPeer && _peers > 0;
}

class _FakePieceProvider implements PieceProvider {
  final Map<int, Piece> _map;

  _FakePieceProvider(this._map);

  @override
  Piece? operator [](int index) => _map[index];

  @override
  int get length => _map.length;
}
