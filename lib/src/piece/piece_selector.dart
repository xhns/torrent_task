import 'base_piece_selector.dart';
import 'piece.dart';
import 'piece_provider.dart';
import 'sequential_piece_selector.dart';

/// Piece选择器。
///
/// 当客户端开始下载前，通过这个类选择出恰当的Piece来下载
abstract class PieceSelector {
  /// 选择恰当的Piece应该Peer下载.
  ///
  /// [remotePeerId]是即将下载的`Peer`的标识，这个标识并**不一定**是协议中的`peer_id`，
  /// 而是`Piece`类中区分`Peer`的标识。
  /// 该方法通过[provider]以及[piecesIndexList]获取对应的`Piece`对象，并在[piecesIndexList]
  /// 集合中进行筛选。
  ///
  Piece? selectPiece(
      String remotePeerId, List<int> piecesIndexList, PieceProvider provider,
      [bool first = false]);

  /// Порядок выбора СТРОГИЙ: селектор сам решает, какой кусок следующий, и
  /// обходить его нельзя.
  ///
  /// `false` (по умолчанию) — обычный rarest-first: [PieceManager] имеет право
  /// на свои эвристики поверх селектора (взять `suggest piece` пира,
  /// предпочесть уже начатый кусок). `true` — последовательный режим: любая
  /// такая эвристика ломает сам смысл «следующий кусок — самый нужный», поэтому
  /// кандидаты идут в селектор целиком и решает только он.
  bool get strictOrder => false;
}

/// Единственное место, где решается, каким селектором качает задача.
///
/// По умолчанию — [BasePieceSelector] (rarest-first, поведение движка «как
/// было»). [sequential] включает [SequentialPieceSelector] с порядком
/// [pieceOrder] («слушать по мере скачивания»). Держится тестом
/// test/sequential_piece_selector_test.dart — иначе «дефолт не менялся» было бы
/// обещанием, а не проверяемым фактом.
PieceSelector createPieceSelector(
    {bool sequential = false, List<int>? pieceOrder}) {
  if (!sequential) return BasePieceSelector();
  return SequentialPieceSelector(pieceOrder: pieceOrder);
}
