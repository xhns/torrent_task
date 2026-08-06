import 'dart:async';

import 'dart:developer';

import 'package:torrent_model/torrent_model.dart';
import '../file/piece_verifier.dart';
import '../peer/bitfield.dart';
import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

typedef PieceCompleteHandle = void Function(int pieceIndex);

typedef PieceVerifyFailedHandle = void Function(int pieceIndex);

class PieceManager implements PieceProvider {
  bool _isFirst = true;

  final Map<int, Piece> _pieces = {};

  // final Set<int> _completedPieces = <int>{};

  final List<PieceCompleteHandle> _pieceCompleteHandles = [];

  final List<PieceVerifyFailedHandle> _pieceVerifyFailedHandles = [];

  final Set<int> _donwloadingPieces = <int>{};

  /// Куски, чей SHA1 сейчас считается. Защищает от повторного запуска проверки
  /// на «опоздавшем» дубле блока, пришедшем пока считается хэш.
  final Set<int> _verifyingPieces = <int>{};

  final PieceSelector _pieceSelector;

  /// Проверяльщик SHA1 собранного куска. `null` означает «принимать кусок по
  /// счётчику под-кусков, как до появления рантайм-проверки» — так делают
  /// только модульные тесты соседних механик; боевой путь ([TorrentTask])
  /// обязан передавать настоящий проверяльщик, иначе битые куски снова начнут
  /// молча доезжать до `progress = 1.0`.
  final PieceVerifier? verifier;

  PieceManager(this._pieceSelector, int piecesNumber, {required this.verifier});

  /// [verifier] намеренно обязателен и нерасширяем по умолчанию: пропустить его
  /// молча (и остаться без проверки хэша) не должно быть возможно случайно.
  static PieceManager createPieceManager(
      PieceSelector pieceSelector, Torrent metaInfo, Bitfield bitfield,
      {required PieceVerifier? verifier}) {
    var p = PieceManager(pieceSelector, metaInfo.pieces.length,
        verifier: verifier);
    p.initPieces(metaInfo, bitfield);
    return p;
  }

  void initPieces(Torrent metaInfo, Bitfield bitfield) {
    for (var i = 0; i < metaInfo.pieces.length; i++) {
      var byteLength = metaInfo.pieceLength;
      if (i == metaInfo.pieces.length - 1) {
        byteLength = metaInfo.lastPriceLength;
      }
      var piece = Piece(metaInfo.pieces[i], i, byteLength);
      if (!bitfield.getBit(i)) _pieces[i] = piece;
    }
  }

  void onPieceComplete(PieceCompleteHandle handle) {
    _pieceCompleteHandles.add(handle);
  }

  void offPieceComplete(PieceCompleteHandle handle) {
    _pieceCompleteHandles.remove(handle);
  }

  /// Кусок собран целиком, но его SHA1 не сошёлся: он уже возвращён в очередь
  /// докачки, а подписчику остаётся раздать куску пиров заново и наказать
  /// источник (см. `PeersManager`).
  void onPieceVerifyFailed(PieceVerifyFailedHandle handle) {
    _pieceVerifyFailedHandles.add(handle);
  }

  void offPieceVerifyFailed(PieceVerifyFailedHandle handle) {
    _pieceVerifyFailedHandles.remove(handle);
  }

  /// 这个接口是用于FIleManager回调使用。
  ///
  /// 只有所有子Piece写入完成才认为该Piece算完成。
  ///
  /// 因为如果仅下载完成就修改bitfield，会造成发送have给对方后，对方请求的子piece还没在
  /// 文件系统中，会读取出错误的数据
  void processSubPieceWriteComplete(int pieceIndex, int begin, int length) {
    var piece = _pieces[pieceIndex];
    if (piece != null) {
      // Проверку запускает только НОВЫЙ под-кусок. Дублирующая запись уже
      // записанного блока (перезапрошенного по таймауту, или «опоздавшего» от
      // второго пира) оставляет [isCompleted] истинным и без этого условия
      // гоняла бы хэширование по кругу: на несошедшемся куске это
      // превращалось в шторм из тысяч проверок в минуту, причём с пустым
      // списком источников — наказывать оказывалось некого.
      var isNew = piece.subPieceWriteComplete(begin);
      if (isNew && piece.isCompleted) _verifyThenComplete(pieceIndex);
    }
  }

  /// Кусок собран — прежде чем объявить его готовым, сверяем SHA1 того, что
  /// реально лежит на диске.
  ///
  /// Раньше здесь сразу шёл [_processCompletePiece]: бит в bitfield ставился по
  /// счётчику записанных под-кусков, и битые байты (например, от сида,
  /// переворачивавшего блоки на стыках файлов) доезжали до `progress = 1.0` и
  /// `onTaskComplete`. Так делают все взрослые клиенты: несошедшийся кусок
  /// перекачивается, а не принимается.
  ///
  /// Пока считается хэш, кусок остаётся в [_pieces] с пустой очередью
  /// под-кусков — выбрать его на скачивание нельзя, поэтому лишних запросов в
  /// сеть не уходит.
  void _verifyThenComplete(int index) {
    var verify = verifier;
    if (verify == null) {
      _processCompletePiece(index);
      return;
    }
    // Дубль блока, доехавший во время проверки, не должен запускать вторую.
    if (!_verifyingPieces.add(index)) return;
    verify.verifyPiece(index).then((ok) {
      _verifyingPieces.remove(index);
      if (isDisposed) return;
      if (ok) {
        _processCompletePiece(index);
      } else {
        _processCorruptedPiece(index);
      }
    });
  }

  /// Кусок не сошёлся с хэшем: бит НЕ ставим, кусок целиком возвращаем в
  /// очередь докачки и сообщаем подписчикам (те накажут источник и раздадут
  /// куску пиров заново).
  void _processCorruptedPiece(int index) {
    var piece = _pieces[index];
    if (piece == null || piece.isDisposed) return;
    piece.resetForRedownload();
    log('Кусок $index не сошёлся с SHA1 — возвращён в очередь докачки целиком',
        name: runtimeType.toString());
    for (var handle in _pieceVerifyFailedHandles) {
      Timer.run(() => handle(index));
    }
  }

  /// Обратный колбэк FileManager: запись под-piece на диск провалилась.
  ///
  /// Возвращает под-piece в очередь докачки, чтобы его перезапросили у этого же
  /// или у другого пира. Без этого piece навсегда застревал в незавершённом
  /// состоянии (см. [Piece.subPieceWriteFailed]).
  ///
  /// Возвращает `true`, если под-piece действительно вернулся в очередь — тогда
  /// вызывающей стороне есть смысл будить спящих пиров.
  bool processSubPieceWriteFailed(int pieceIndex, int begin, int length) {
    var piece = _pieces[pieceIndex];
    if (piece == null || piece.isDisposed) return false;
    return piece.subPieceWriteFailed(begin);
  }

  Piece? selectPiece(String remotePeerId, List<int> remoteHavePieces,
      PieceProvider provider, final Set<int> suggestPieces) {
    // 查看当前下载piece中是否可以使用该peer
    var avalidatePiece = <int>[];
    // 优先下载Suggest Pieces
    if (suggestPieces.isNotEmpty) {
      for (var i = 0; i < suggestPieces.length; i++) {
        var p = _pieces[suggestPieces.elementAt(i)];
        if (p != null && p.haveAvalidateSubPiece()) {
          processDownloadingPiece(p.index!);
          return p;
        }
      }
    }
    var candidatePieces = remoteHavePieces;
    for (var i = 0; i < _donwloadingPieces.length; i++) {
      var p = _pieces[_donwloadingPieces.elementAt(i)];
      if (p == null) continue;
      if (p.containsAvalidatePeer(remotePeerId) && p.haveAvalidateSubPiece()) {
        avalidatePiece.add(p.index!);
      }
    }

    // 如果可以下载正在下载中的piece，就下载该piece（多个Peer同时下载一个piece使其尽快完成的原则）
    if (avalidatePiece.isNotEmpty) {
      candidatePieces = avalidatePiece;
    }
    var piece = _pieceSelector.selectPiece(
        remotePeerId, candidatePieces, this, _isFirst);
    _isFirst = false;
    if (piece == null) return null;
    processDownloadingPiece(piece.index!);
    return piece;
  }

  void processDownloadingPiece(int pieceIndex) {
    _donwloadingPieces.add(pieceIndex);
  }

  /// 完成后的Piece需要一些处理
  /// - 从`_pieces`列表中删除
  /// - 从`_downloadingPieces`列表中删除
  /// - 通知监听器
  void _processCompletePiece(int index) {
    var piece = _pieces.remove(index);
    _donwloadingPieces.remove(index);
    if (piece != null) {
      piece.dispose();
      for (var handle in _pieceCompleteHandles) {
        Timer.run(() => handle(index));
      }
    }
  }

  bool _disposed = false;

  bool get isDisposed => _disposed;

  void dispose() {
    if (isDisposed) return;
    _disposed = true;
    _pieces.forEach((key, value) {
      value.dispose();
    });
    _pieces.clear();
    _pieceCompleteHandles.clear();
    _pieceVerifyFailedHandles.clear();
    _donwloadingPieces.clear();
    _verifyingPieces.clear();
  }

  @override
  Piece? operator [](index) {
    return _pieces[index];
  }

  // @override
  // Piece getPiece(int index) {
  //   return _pieces[index];
  // }

  @override
  int get length => _pieces.length;
}
