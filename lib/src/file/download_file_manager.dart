import 'dart:async';
import 'dart:io';
import 'dart:developer';

import 'package:torrent_model/torrent_model.dart';
import 'package:path/path.dart' as path_pkg;
import '../peer/peer_base.dart';

import 'download_file.dart';
import 'state_file.dart';

typedef SubPieceCompleteHandle = void Function(
    int pieceIndex, int begin, int length);

typedef SubPieceReadHandle = void Function(
    int pieceIndex, int begin, List<int> block);

class DownloadFileManager {
  final Torrent metainfo;

  final Set<DownloadFile> _files = {};

  List<List<DownloadFile>?>? _piece2fileMap;

  final Map<String, List<int>?> _file2pieceMap = {};

  final List<SubPieceCompleteHandle> _subPieceCompleteHandles = [];

  final List<SubPieceCompleteHandle> _subPieceFailedHandles = [];

  final List<SubPieceReadHandle> _subPieceReadHandles = [];

  final List<void Function(String path)> _fileCompleteHandles = [];

  final StateFile _stateFile;

  String? _parentDir;

  /// TODO
  /// - 没有建立文件读取缓存
  DownloadFileManager(this.metainfo, this._stateFile) {
    _piece2fileMap = List.filled(_stateFile.bitfield.piecesNum,null);
  }

  static Future<DownloadFileManager> createFileManager(
      Torrent metainfo, String localDirectory, StateFile stateFile) {
    var manager = DownloadFileManager(metainfo, stateFile);
    // manager._totalDownloaded = stateFile.downloaded;
    return manager._init(localDirectory);
  }

  Future<DownloadFileManager> _init(String directory) async {
    /*
    var lastc = directory.substring(directory.length - 1);
    if (lastc != '\\' || lastc != '/') {
      directory = directory + '\\';
    }
     */
    _initFileMap(directory);
    return this;
  }

  Bitfield get localBitfield => _stateFile.bitfield;

  bool localHave(int index) {
    return _stateFile.bitfield.getBit(index);
  }

  bool get isAllComplete {
    return _stateFile.bitfield.piecesNum ==
        _stateFile.bitfield.completedPieces.length;
  }

  int get piecesNumber => _stateFile.bitfield.piecesNum;

  void _subPieceWriteComplete(int pieceIndex, int begin, int length) {
    for (var handle in _subPieceCompleteHandles) {
      Timer.run(() => handle(pieceIndex, begin, length));
    }
  }

  void _subPieceWriteFailed(int pieceIndex, int begin, int length) {
    for (var handle in _subPieceFailedHandles) {
      Timer.run(() => handle(pieceIndex, begin, length));
    }
  }

  Future<bool> updateBitfield(int index, [bool have = true]) {
    return _stateFile.updateBitfield(index, have);
  }

  // Future<bool> updateBitfields(List<int> indices, [List<bool> haves]) {
  //   return _stateFile.updateBitfields(indices, haves);
  // }

  Future<bool> updateUpload(int uploaded) {
    return _stateFile.updateUploaded(uploaded);
  }

  void _subPieceReadComplete(int pieceIndex, int begin, List<int> block) {
    for (var h in _subPieceReadHandles) {
      Timer.run(() => h(pieceIndex, begin, block));
    }
  }

  int get downloaded => _stateFile.downloaded;

  int get uploaded => _stateFile.uploaded;

  /// 该方法看似只将缓冲区内容写入磁盘，实际上
  /// 每当缓存写入后都会认为该[pieceIndex]对应`Piece`已经完成，则会去移除
  /// `_file2pieceMap`中文件对应的piece index，当全部移除完毕，会抛出File Complete事件
  Future<bool> flushFiles(Set<int> pieceIndices) async {
    var d = _stateFile.downloaded;
    var flushed = <String>{};
    for (var i = 0; i < pieceIndices.length; i++) {
      var pieceIndex = pieceIndices.elementAt(i);
      var fs = _piece2fileMap![pieceIndex];
      if (fs == null || fs.isEmpty) continue;
      for (var i = 0; i < fs.length; i++) {
        var file = fs[i];
        var pieces = _file2pieceMap[file.filePath];
        if (pieces == null) continue;
        pieces.remove(pieceIndex);
        if (flushed.add(file.filePath)) {
          await file.requestFlush();
        }
        if (pieces.isEmpty && _file2pieceMap[file.filePath] != null) {
          _file2pieceMap[file.filePath] = null;
          _fireFileComplete(file.filePath);
        }
      }
    }

    var msg =
        '已下载：${d / (1024 * 1024)} mb , 完成度 ${((d / metainfo.length!.toInt()) * 10000).toInt() / 100} %';
    log(msg, name: runtimeType.toString());
    return true;
  }

  void onFileComplete(void Function(String) h) {
    _fileCompleteHandles.add(h);
  }

  void offFileComplete(void Function(String) h) {
    _fileCompleteHandles.remove(h);
  }

  void _fireFileComplete(String path) {
    for (var element in _fileCompleteHandles) {
      Timer.run(() => element(path));
    }
  }

  void _initFileMap(String directory) {
    _parentDir = directory;
    for (var i = 0; i < metainfo.files.length; i++) {
      var file = metainfo.files[i];
      var df = DownloadFile(path_pkg.join(directory,file.path), file.offset, file.length);
      _files.add(df);
      var fs = df.start;
      var fe = df.end;
      var startPiece = fs ~/ metainfo.pieceLength!;
      var endPiece = fe ~/ metainfo.pieceLength!;
      var pieces = _file2pieceMap[df.filePath];
      if (pieces == null) {
        pieces = <int>[];
        _file2pieceMap[df.filePath] = pieces;
      }
      if (fe.remainder(metainfo.pieceLength!) == 0) endPiece--;
      for (var pieceIndex = startPiece; pieceIndex <= endPiece; pieceIndex++) {
        var l = _piece2fileMap![pieceIndex];
        if (l == null) {
          l = <DownloadFile>[];
          _piece2fileMap![pieceIndex] = l;
          if (!localHave(pieceIndex)) pieces.add(pieceIndex);
        }
        l.add(df);
      }
    }
  }

  void onSubPieceReadComplete(SubPieceReadHandle handle) {
    _subPieceReadHandles.add(handle);
  }

  void offSubPieceReadComplete(SubPieceReadHandle handle) {
    _subPieceReadHandles.remove(handle);
  }

  void onSubPieceWriteComplete(SubPieceCompleteHandle handle) {
    _subPieceCompleteHandles.add(handle);
  }

  void offSubPieceWriteComplete(SubPieceCompleteHandle handle) {
    _subPieceCompleteHandles.remove(handle);
  }

  void onSubPieceWriteFailed(SubPieceCompleteHandle handle) {
    _subPieceFailedHandles.add(handle);
  }

  void offSubPieceWriteFailed(SubPieceCompleteHandle handle) {
    _subPieceFailedHandles.remove(handle);
  }

  void readFile(int pieceIndex, int begin, int length) {
    var tempFiles = _piece2fileMap![pieceIndex];
    var ps = pieceIndex * metainfo.pieceLength! + begin;
    var pe = ps + length;
    if (tempFiles == null || tempFiles.isEmpty) return;
    // Порядок кусочков в собираемом блоке ОБЯЗАН совпадать с порядком файлов в
    // торренте: блок склеивается из хвоста одного файла и головы следующего.
    // Раньше здесь стоял `Stream.fromFutures(...).fold(...)`, а он отдаёт
    // элементы в порядке ЗАВЕРШЕНИЯ чтений, а не в порядке списка. Файлы —
    // независимые очереди операций: если очередь первого файла занята, его
    // чтение завершается позже, и кусочки склеивались задом наперёд — пиру
    // уезжал битый блок на каждом стыке файлов. `Future.wait` сохраняет
    // порядок списка. Держится тестом test/file_boundary_test.dart.
    var futures = <Future<List<int>>>[];
    for (var i = 0; i < tempFiles.length; i++) {
      var tempFile = tempFiles[i];
      var re = _mapDownloadFilePosition(ps, pe, length, tempFile);
      if (re == null) continue;
      var substart = re['begin'];
      var position = re['position'];
      var subend = re['end'];
      if (subend <= substart) continue;
      futures.add(tempFile.requestRead(position, subend - substart));
    }
    if (futures.isEmpty) return;
    Future.wait(futures).then((parts) {
      var block = <int>[];
      for (var part in parts) {
        block.addAll(part);
      }
      if (block.length != length) {
        // Короткое чтение (файл обрезан/недоступен — `_read` отдаёт пустой
        // список на ошибке). Отдать такой блок пиру нельзя: он запишет его как
        // полноценный под-piece и получит дыру. Молчим — пир перезапросит.
        log(
          'Чтение блока ($pieceIndex, $begin, $length) отдало '
          '${block.length} байт — блок не отправляем',
          name: runtimeType.toString(),
        );
        return;
      }
      _subPieceReadComplete(pieceIndex, begin, block);
    }, onError: (e) {
      log(
        'Ошибка чтения блока ($pieceIndex, $begin, $length)',
        error: e,
        name: runtimeType.toString(),
      );
    });
    return;
  }

  ///
  /// 将`Sub Piece`的内容写入文件中。完成后会发送 `sub piece complete`事件，
  /// 如果失败，就会发送`sub piece failed`事件
  ///
  /// 该`Sub Piece`是来自于[pieceIndex]对应的`Piece`，内容为[block],起始位置是[begin]。
  /// 该类不会去验证写入的Sub Piece是否重复，重复内容直接覆盖之前内容
  void writeFile(int pieceIndex, int begin, List<int> block) {
    var tempFiles = _piece2fileMap![pieceIndex];
    var ps = pieceIndex * metainfo.pieceLength! + begin;
    var blockSize = block.length;
    var pe = ps + blockSize;
    if (tempFiles == null || tempFiles.isEmpty) {
      // Раньше здесь был немой `return`: не летело ни `complete`, ни `failed`,
      // а под-piece уже был переложен в `Piece._writtingSubPieces` — он
      // застревал там навсегда и piece не мог завершиться. Отдаём `failed`,
      // чтобы под-piece вернулся в очередь докачки по общему пути.
      log(
        'Не найдены файлы для piece $pieceIndex — запись под-piece '
        '($begin, $blockSize) невозможна',
        name: runtimeType.toString(),
      );
      _subPieceWriteFailed(pieceIndex, begin, blockSize);
      return;
    }
    var futures = <Future<bool>>[];
    for (var i = 0; i < tempFiles.length; i++) {
      var tempFile = tempFiles[i];
      var re = _mapDownloadFilePosition(ps, pe, blockSize, tempFile);
      if (re == null) continue;
      var substart = re['begin'];
      var position = re['position'];
      var subend = re['end'];
      futures.add(tempFile.requestWrite(position, block, substart, subend));
    }
    if (futures.isEmpty) {
      // Ни один файл не покрыл блок: `fold` по пустому потоку вернул бы `true`
      // и мы отрапортовали бы об успешной записи того, что не записано (piece
      // ушёл бы в bitfield с дырой). Считаем это провалом записи.
      log(
        'Блок ($pieceIndex, $begin, $blockSize) не покрыт ни одним файлом',
        name: runtimeType.toString(),
      );
      _subPieceWriteFailed(pieceIndex, begin, blockSize);
      return;
    }
    Future.wait(futures).then((results) {
      var result = results.every((ok) => ok);
      if (result) {
        _subPieceWriteComplete(pieceIndex, begin, blockSize);
      } else {
        _subPieceWriteFailed(pieceIndex, begin, blockSize);
      }
    }, onError: (e) {
      // `DownloadFile.requestWrite` возвращает `false` только на ошибках самой
      // записи; открытие файла (`getRandomAccessFile`) кидает наружу —
      // заблокированный антивирусом/индексатором файл, отозванные права,
      // недоступный путь. Без этого обработчика ошибка уходила в unhandled, ни
      // одно событие не летело, и под-piece навсегда оставался «пишущимся».
      log(
        'Ошибка записи под-piece ($pieceIndex, $begin, $blockSize)',
        error: e,
        name: runtimeType.toString(),
      );
      _subPieceWriteFailed(pieceIndex, begin, blockSize);
    });
    return;
  }

  Map? _mapDownloadFilePosition(
      int pieceStart, int pieceEnd, int length, DownloadFile tempFile) {
    var fs = tempFile.start;
    var fe = fs + tempFile.length;
    if (pieceEnd < fs || pieceStart > fe) return null;
    var position = 0;
    var substart = 0;
    if (fs <= pieceStart) {
      position = pieceStart - fs;
      substart = 0;
    } else {
      position = 0;
      substart = fs - pieceStart;
    }
    var subend = substart;
    if (fe >= pieceEnd) {
      subend = length;
    } else {
      subend = fe - pieceStart;
    }
    return {'position': position, 'begin': substart, 'end': subend};
  }

  Future close() async {
    await _stateFile.close();
    for (var i = 0; i < _files.length; i++) {
      var file = _files.elementAt(i);
      await file.close();
    }
    _clean();
  }

  void _clean() {
    _subPieceCompleteHandles.clear();
    _subPieceFailedHandles.clear();
    _subPieceReadHandles.clear();
    _fileCompleteHandles.clear();
    _file2pieceMap.clear();
    _piece2fileMap = null;
  }

  Future delete() async {
    await _stateFile.delete();
    var dirs = <String>{};
    for (var i = 0; i < _files.length; i++) {
      var file = _files.elementAt(i);
      log('deleting ${file.filePath}', name: runtimeType.toString());
      await file.delete();
      var fsFile =  File(file.filePath);
      if(fsFile.existsSync()) {
        fsFile.deleteSync();
      }
      var tmpPath = file.filePath;
      do{
        tmpPath = path_pkg.dirname(tmpPath);
      }while(path_pkg.dirname(tmpPath) != _parentDir && path_pkg.dirname(tmpPath) != '.' && path_pkg.dirname(tmpPath) != '/');

      dirs.add(tmpPath);
    }

    for(var dir in dirs){
      if(dir != '.' && dir != '/') {
        log('deleting parent dir $dir', name: runtimeType.toString());
        Directory(dir).deleteSync(recursive: true);
      }
    }
    //remove empty dir if exists
    _clean();
  }
}
