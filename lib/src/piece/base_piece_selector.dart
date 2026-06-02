import 'package:dartorrent_common/dartorrent_common.dart';

import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

///
/// `Piece`基础选择器。
///
/// 基本策略为：
///
/// - `Piece`可用`Peer`数量最多
/// - 在可用`Peer`数量都相同的情况下，选用`Sub Piece`数量最少的
class BasePieceSelector implements PieceSelector {
  @override
  Piece? selectPiece(
      String remotePeerId, List<int> piecesIndexList, PieceProvider provider,
      [bool random = false]) {
    // random = true;
    var maxList = <Piece>[];
    Piece? a;
    int? startIndex;
    for (var i = 0; i < piecesIndexList.length; i++) {
      var p = provider[piecesIndexList[i]];
      if (p != null &&
          p.haveAvalidateSubPiece() &&
          p.containsAvalidatePeer(remotePeerId)) {
        a = p;
        startIndex = i;
        break;
      }
    }
    // No downloadable piece available for this peer.
    if (a == null || startIndex == null) return null;
    var current = a;
    maxList.add(current);
    for (var i = startIndex; i < piecesIndexList.length; i++) {
      var p = provider[piecesIndexList[i]];
      if (p == null ||
          !p.haveAvalidateSubPiece() ||
          !p.containsAvalidatePeer(remotePeerId)) {
        continue;
      }
      // 选择稀有piece
      if (current.avalidatePeersCount > p.avalidatePeersCount) {
        if (!random) return p;
        maxList.clear();
        current = p;
        maxList.add(current);
      } else {
        if (current.avalidatePeersCount == p.avalidatePeersCount) {
          // 如果同样数量可用下载peer的piece所具有的sub piece少，优先处理
          if (p.avalidateSubPieceCount < current.avalidateSubPieceCount) {
            if (!random) return p;
            maxList.clear();
            current = p;
            maxList.add(current);
          } else {
            if (p.avalidateSubPieceCount == current.avalidateSubPieceCount) {
              if (!random) return p;
              maxList.add(p);
              current = p;
            }
          }
        }
      }
    }
    if (random) {
      return maxList[randomInt(maxList.length)];
    }
    return current;
  }
}
