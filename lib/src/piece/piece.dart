import 'dart:collection';

import '../utils.dart';

class Piece {
  final String? hashString;

  final int? byteLength;

  final int? index;

  final Set<String> _avalidatePeers = <String>{};

  Queue<int>? _subPiecesQueue;

  final Set<int> _downloadedSubPieces = <int>{};

  final Set<int> _writtingSubPieces = <int>{};

  int _subPiecesCount = 0;

  Piece(this.hashString, this.index, this.byteLength,
      [int requestLength = DEFAULT_REQUEST_LENGTH]) {
    if (requestLength <= 0) {
      throw Exception('Request length should bigger than zero');
    }
    if (requestLength > DEFAULT_REQUEST_LENGTH) {
      throw Exception('Request length should smaller than 16kb');
    }
    _subPiecesCount = byteLength! ~/ requestLength;
    if (_subPiecesCount * requestLength != byteLength) {
      _subPiecesCount++;
    }
    _subPiecesQueue =
        Queue.from(List.generate(_subPiecesCount, (index) => index));
  }

  bool get isDownloading {
    if (subPiecesCount == 0) return false;
    if (isCompleted) return false;
    return subPiecesCount !=
        _downloadedSubPieces.length +
            _subPiecesQueue!.length +
            _writtingSubPieces.length;
  }

  Queue<int> get subPieceQueue => _subPiecesQueue!;

  int get subPiecesCount => _subPiecesCount;

  double get completed {
    if (subPiecesCount == 0) return 0;
    return _downloadedSubPieces.length / subPiecesCount;
  }

  int get downloadedSubPiecesCount => _downloadedSubPieces.length;

  int get writtingSubPiecesCount => _writtingSubPieces.length;

  bool haveAvalidateSubPiece() {
    if (_subPiecesCount == 0) return false;
    return _subPiecesQueue!.isNotEmpty;
  }

  int get avalidatePeersCount => _avalidatePeers.length;

  int get avalidateSubPieceCount {
    if (_subPiecesCount == 0) return 0;
    return _subPiecesQueue!.length;
  }

  bool get isCompleted {
    if (subPiecesCount == 0) return false;
    return _downloadedSubPieces.length == subPiecesCount;
  }

  ///
  /// 子Piece下载完成。
  ///
  /// 将子piece放入 `_writtingSubPieces` 队列中
  /// 设置子Piece为完成状态。如果该子Piece已经设置过，返回`false`,没有设置
  /// 过说明设置成功，返回`true`
  bool subPieceDownloadComplete(int begin) {
    var subindex = begin ~/ DEFAULT_REQUEST_LENGTH;
    _subPiecesQueue!.remove(subindex);
    return _writtingSubPieces.add(subindex);
  }


  bool subPieceWriteComplete(int begin) {
    var subindex = begin ~/ DEFAULT_REQUEST_LENGTH;
    // Под-piece мог остаться в очереди докачки: его туда вернули по таймауту
    // запроса/reject'у или целиком по [resetForRedownload], а «опоздавшая»
    // запись прежнего экземпляра блока дошла уже после. Записанный блок в
    // очереди держать нельзя — иначе счётчик `_downloadedSubPieces` дорастает
    // до [isCompleted], пока очередь ещё не пуста, и хэш считается по куску,
    // который сам себя считает недокачанным.
    _subPiecesQueue!.remove(subindex);
    _writtingSubPieces.remove(subindex);
    var re = _downloadedSubPieces.add(subindex);
    if (isCompleted) {
      clearAvalidatePeer();
    }
    return re;
  }

  ///
  /// Кусок собран целиком, но SHA1 не сошёлся — сбрасываем его в исходное
  /// состояние, чтобы скачать заново.
  ///
  /// Возвращаем в очередь ВСЕ под-куски, а не только «подозрительные»: какой
  /// именно блок приехал битым, по хэшу куска не видно, а частичная докачка
  /// оставила бы битые байты на диске навсегда.
  ///
  /// Доступных пиров при завершении куска очистил [subPieceWriteComplete]
  /// ([clearAvalidatePeer]), и здесь мы их намеренно не восстанавливаем: пиров
  /// заново раздаёт `PeersManager`, уже без того, кого забанили за битый кусок.
  void resetForRedownload() {
    if (isDisposed) return;
    // Прошлый вердикт отработан: кто качает кусок заново, решает вызывающая
    // сторона (`PeersManager`), а не остатки прежнего ограничения.
    liftRestriction();
    _downloadedSubPieces.clear();
    _writtingSubPieces.clear();
    _subPiecesQueue!.clear();
    for (var i = 0; i < _subPiecesCount; i++) {
      _subPiecesQueue!.addLast(i);
    }
  }

  ///
  /// Запись под-piece на диск ПРОВАЛИЛАСЬ — обратная операция к
  /// [subPieceDownloadComplete].
  ///
  /// Без неё под-piece навсегда оставался в [_writtingSubPieces]: очередь
  /// докачки пуста, [isCompleted] никогда не наступает (счётчик
  /// `_downloadedSubPieces` не дорос), и piece не может ни завершиться, ни быть
  /// перезапрошен — загрузка замирала на ~99% до ручной паузы+recheck.
  ///
  /// Возвращаем под-piece в НАЧАЛО очереди (addFirst): это остаток почти
  /// готового куска, его выгодно дозабрать раньше новых.
  ///
  /// [pushSubPiece] здесь не годится — он отказывает как раз для тех индексов,
  /// что лежат в [_writtingSubPieces]. Возвращает `true`, если под-piece
  /// действительно вернулся в очередь.
  bool subPieceWriteFailed(int begin) {
    var subindex = begin ~/ DEFAULT_REQUEST_LENGTH;
    // Не наш под-piece (или уже возвращён/дописан) — ничего не делаем.
    if (!_writtingSubPieces.remove(subindex)) return false;
    // Параллельная успешная запись того же блока другим пиром уже закрыла его.
    if (_downloadedSubPieces.contains(subindex)) return false;
    if (_subPiecesQueue!.contains(subindex)) return false;
    _subPiecesQueue!.addFirst(subindex);
    return true;
  }

  ///
  ///子Piece [subIndex]是否还在。
  ///
  ///当子Piece被弹出栈用于下载，或者子Piece已经下载完成，那么就视为该Piece已经不再包含该子Piece
  bool containsSubpiece(int subIndex) {
    return subPieceQueue.contains(subIndex);
  }

  bool containsAvalidatePeer(String id) {
    return _avalidatePeers.contains(id);
  }

  /// Пир, которому кусок отдан в единоличную перекачку, либо `null`.
  String? _restrictedToPeerId;

  String? get restrictedToPeerId => _restrictedToPeerId;

  /// Разрешено ли пиру [id] качать этот кусок.
  bool allowsPeer(String id) =>
      _restrictedToPeerId == null || _restrictedToPeerId == id;

  ///
  /// Отдать кусок в единоличную перекачку пиру [peerId].
  ///
  /// Нужно, когда кусок не сошёлся с SHA1, а виновника определить не удалось:
  /// пока кусок собирается из блоков нескольких источников, вердикт «виноват
  /// такой-то» невозможен в принципе — и на живом прогоне это давало вечный
  /// цикл (один и тот же кусок качался сотни раз в секунду, вклад пиров всегда
  /// ровно 50/50, никто не наказан). Перекачка у одного источника делает
  /// следующий вердикт адресным.
  ///
  /// Ограничение снимается [liftRestriction] либо уходом самого пира
  /// ([removeAvalidatePeer]).
  void restrictToPeer(String peerId) {
    _restrictedToPeerId = peerId;
    _avalidatePeers
      ..clear()
      ..add(peerId);
  }

  void liftRestriction() {
    _restrictedToPeerId = null;
  }

  bool removeSubpiece(int subIndex) {
    return subPieceQueue.remove(subIndex);
  }

  bool addAvalidatePeer(String id) {
    // Кусок отдан в единоличную перекачку — чужих не пускаем, иначе следующая
    // попытка снова соберётся вскладчину и виновника опять будет не видно.
    if (!allowsPeer(id)) return false;
    return _avalidatePeers.add(id);
  }

  bool removeAvalidatePeer(String id) {
    // Ушёл тот, кому кусок был отдан единолично — снимаем ограничение, иначе
    // кусок больше некому качать.
    if (_restrictedToPeerId == id) liftRestriction();
    return _avalidatePeers.remove(id);
  }

  void clearAvalidatePeer() {
    _avalidatePeers.clear();
  }

  int? popSubPiece() {
    if (subPieceQueue.isNotEmpty) return subPieceQueue.removeFirst();
    return null;
  }

  bool pushSubPiece(int subIndex) {
    if (subPieceQueue.contains(subIndex) ||
        _writtingSubPieces.contains(subIndex) ||
        _downloadedSubPieces.contains(subIndex)) {
      return false;
    }
    subPieceQueue.addFirst(subIndex);
    return true;
  }

  int? popLastSubPiece() {
    if (subPieceQueue.isNotEmpty) return subPieceQueue.removeLast();
    return null;
  }

  bool pushSubPieceLast(int index) {
    if (subPieceQueue.contains(index) ||
        _writtingSubPieces.contains(index) ||
        _downloadedSubPieces.contains(index)) {
      return false;
    }
    subPieceQueue.addLast(index);
    return true;
  }

  bool _disposed = false;

  bool get isDisposed => _disposed;

  void dispose() {
    if (isDisposed) return;
    _disposed = true;
    _avalidatePeers.clear();
    _downloadedSubPieces.clear();
    _writtingSubPieces.clear();
  }

  @override
  int get hashCode => hashString.hashCode;

  @override
  bool operator ==(other) {
    if (other is Piece) {
      return other.hashString == hashString;
    }
    return false;
  }
}
