import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

/// Селектор кусков для ПОСЛЕДОВАТЕЛЬНОЙ загрузки.
///
/// Нужен режиму «слушать по мере скачивания»: куски приходят по порядку, и
/// первая глава книги становится пригодной для воспроизведения задолго до
/// конца загрузки. Это осознанный размен: последовательный порядок хуже для
/// здоровья роя, чем rarest-first (редкие куски расходятся медленнее), поэтому
/// он ВКЛЮЧАЕТСЯ ЯВНО, а по умолчанию задача качает [BasePieceSelector]'ом.
///
/// Порядок задаётся [pieceOrder] — списком индексов кусков в желаемом порядке
/// скачивания (самый нужный первым). Он нужен, потому что порядок файлов в
/// торренте не обязан совпадать с порядком ВОСПРОИЗВЕДЕНИЯ: приложение
/// сортирует главы по имени и раскладывает их куски в нужном ему порядке.
/// `null`/пустой список — естественный порядок индексов (0, 1, 2, …).
///
/// Куски, не перечисленные в [pieceOrder], качаются ПОСЛЕ перечисленных, между
/// собой — по возрастанию индекса.
///
/// В отличие от [BasePieceSelector] здесь нет ни редкости, ни случайного
/// разброса по равным кандидатам: приоритет строгий и детерминированный.
/// Параллелизм при этом не теряется — [PieceManager] раздаёт разным пирам
/// под-куски одного и того же куска и предпочитает уже начатые куски, поэтому
/// «все качают начало» не вырождается в «качает один пир».
class SequentialPieceSelector implements PieceSelector {
  SequentialPieceSelector({Iterable<int>? pieceOrder})
      : _rank = _buildRanks(pieceOrder);

  /// Индекс куска → его место в очереди (меньше = раньше). Куска здесь нет —
  /// см. [rankOf].
  final Map<int, int> _rank;

  static Map<int, int> _buildRanks(Iterable<int>? order) {
    final map = <int, int>{};
    if (order == null) return map;
    var next = 0;
    for (final index in order) {
      // Повтор индекса не сдвигает ранги: место в очереди задаёт ПЕРВОЕ
      // упоминание.
      if (map.containsKey(index)) continue;
      map[index] = next++;
    }
    return map;
  }

  /// Место куска в очереди скачивания. Неперечисленные куски получают ранг
  /// заведомо больше любого перечисленного (их всего [_rank.length]), при этом
  /// между собой сохраняют порядок индексов.
  int rankOf(int pieceIndex) => _rank[pieceIndex] ?? (_rank.length + pieceIndex);

  /// Порядок строгий: [PieceManager] не имеет права подсунуть кусок мимо
  /// очереди (ни `suggest piece` пира, ни «уже начатый» кусок) — иначе первая
  /// глава книги перестала бы быть первой, а именно ради неё режим и включают.
  /// Уже начатые куски и так стоят в начале очереди: их ранг ниже.
  @override
  bool get strictOrder => true;

  /// [random] игнорируется намеренно: в последовательном режиме случайность
  /// ломала бы сам смысл — «следующий кусок всегда самый нужный».
  @override
  Piece? selectPiece(
      String remotePeerId, List<int> piecesIndexList, PieceProvider provider,
      [bool random = false]) {
    Piece? best;
    var bestRank = 0;
    for (var i = 0; i < piecesIndexList.length; i++) {
      var p = provider[piecesIndexList[i]];
      if (p == null ||
          !p.haveAvalidateSubPiece() ||
          !p.containsAvalidatePeer(remotePeerId)) {
        continue;
      }
      var rank = rankOf(p.index!);
      if (best == null || rank < bestRank) {
        best = p;
        bestRank = rank;
      }
    }
    return best;
  }
}
