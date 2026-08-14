import 'package:dartorrent_common/dartorrent_common.dart';

import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

///
/// `Piece` 基础选择器（rarest-first 策略）。
///
/// 选择策略：
///
/// - 在该 `Peer` 可下载的候选 `Piece` 中，优先选择可用 `Peer` 数量最少的
///   （即最稀有的）`Piece`；
/// - 可用 `Peer` 数量相同时，优先选择剩余 `Sub Piece` 数量最少的，
///   以尽快补齐已经下载了一部分的 `Piece`；
/// - 上述两项都相同时，在并列的候选中随机挑选一个，避免所有 `Peer`
///   都抢同一个 `Piece`。
///
/// 这是标准的 BitTorrent rarest-first 策略：优先获取整个 swarm 中最稀缺的
/// 数据，从而提升副本分布的健康度。`random` 参数仅影响并列项的处理，不再
/// 改变是否走 rarest-first：无论 `random` 是 `true` 还是 `false`，返回的
/// 都是真正最稀有的 `Piece`。
class BasePieceSelector implements PieceSelector {
  /// rarest-first не строгий: эвристики [PieceManager] (suggest-куски пира,
  /// предпочтение уже начатых кусков) остаются в силе, как и было.
  @override
  bool get strictOrder => false;

  @override
  Piece? selectPiece(
      String remotePeerId, List<int> piecesIndexList, PieceProvider provider,
      [bool random = false]) {
    // 收集该 peer 真正可下载的候选 piece（有可用 sub piece，且该 peer 持有）。
    Piece? best;
    // 与 best 在 (availablePeers, availableSubPieces) 上完全并列的候选集合，
    // 用于并列时的（可选）随机决断。
    var ties = <Piece>[];
    for (var i = 0; i < piecesIndexList.length; i++) {
      var p = provider[piecesIndexList[i]];
      if (p == null ||
          !p.haveAvalidateSubPiece() ||
          !p.containsAvalidatePeer(remotePeerId)) {
        continue;
      }
      if (best == null) {
        best = p;
        ties = [p];
        continue;
      }
      var cmp = _compare(p, best);
      if (cmp < 0) {
        // p 更稀有（或同样稀有但 sub piece 更少）—— 成为新的最优。
        best = p;
        ties = [p];
      } else if (cmp == 0) {
        // 与当前最优完全并列。
        ties.add(p);
      }
    }
    // 没有任何可下载的 piece。
    if (best == null) return null;
    // 默认（random == true 时）在并列项里随机选，分散 peer 的请求；
    // random == false 时返回稳定的第一个最优项以保证确定性。
    if (random && ties.length > 1) {
      return ties[randomInt(ties.length)];
    }
    return best;
  }

  /// 比较两个候选 `Piece` 的优先级。
  ///
  /// 返回值 < 0 表示 [a] 比 [b] 更应优先下载（更稀有，或同样稀有但剩余
  /// sub piece 更少）；> 0 表示 [b] 更优先；0 表示二者并列。
  int _compare(Piece a, Piece b) {
    // 主键：可用 peer 数量越少越稀有，优先。
    if (a.avalidatePeersCount != b.avalidatePeersCount) {
      return a.avalidatePeersCount - b.avalidatePeersCount;
    }
    // 次键：剩余 sub piece 越少越优先（尽快补齐部分下载的 piece）。
    return a.avalidateSubPieceCount - b.avalidateSubPieceCount;
  }
}
