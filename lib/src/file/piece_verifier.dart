import 'dart:async';
import 'dart:isolate';

import 'package:torrent_model/torrent_model.dart';

import 'piece_layout.dart';

/// Проверяльщик куска: «байты куска [pieceIndex], лежащие сейчас на диске,
/// сходятся с SHA1 из metainfo?».
///
/// Вклинивается между «все под-куски записаны» и «бит выставлен в bitfield»
/// (см. `PieceManager.processSubPieceWriteComplete`). Без него bitfield растёт
/// по счётчику записанных под-кусков, и битые данные молча доезжают до
/// `progress = 1.0` + `onTaskComplete`.
abstract class PieceVerifier {
  /// `true` — кусок на диске сошёлся с хэшем и его можно принимать.
  Future<bool> verifyPiece(int pieceIndex);

  Future<void> dispose();
}

/// Запрос, ожидающий ответа от изолята.
class _Pending {
  final Completer<bool> completer = Completer<bool>();
}

/// [PieceVerifier], который считает SHA1 в отдельном изоляте.
///
/// Почему изолят: книга весит до 3 ГБ, кусок — от 256 КБ до 4 МБ, и хэшировать
/// его надо на КАЖДОМ завершённом куске. И чтение с диска, и сам SHA1 целиком
/// уезжают из главного изолята, поэтому UI приложения не дёргается на каждом
/// куске. Главный изолят только шлёт номер куска и получает `bool`.
///
/// Изолят держит собственные read-хэндлы на файлы книги (кэш переживает
/// вызовы) и читает порциями по [readChunkSize] — пик памяти не зависит от
/// размера куска. Пишущая сторона живёт в главном изоляте и к моменту запроса
/// уже завершила все `write` этого куска, так что изолят видит актуальные
/// байты через страничный кэш ОС.
///
/// Запросы обрабатываются по одному, в порядке поступления: хэширование
/// заметно быстрее сети (см. замеры в отчёте), очередь не растёт.
class IsolatePieceVerifier implements PieceVerifier {
  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;

  final Map<int, _Pending> _pending = {};
  int _nextId = 0;
  bool _disposed = false;

  /// Сколько кусков проверено и сколько из них не сошлось — для диагностики и
  /// замеров.
  int verifiedCount = 0;
  int failedCount = 0;

  /// Суммарное время, проведённое изолятом внутри хэширования (микросекунды).
  int hashMicros = 0;

  IsolatePieceVerifier._(this._isolate, this._toWorker, this._fromWorker);

  /// Поднять изолят-хэшер для [metainfo], файлы которого лежат в
  /// [downloadDir].
  static Future<IsolatePieceVerifier> spawn(
      Torrent metainfo, String downloadDir) async {
    final layout = TorrentDiskLayout.of(metainfo, downloadDir);
    final fromWorker = ReceivePort();
    final ready = Completer<SendPort>();
    // Единственная подписка на порт: первое сообщение изолята — его SendPort,
    // все последующие — ответы на проверки.
    IsolatePieceVerifier? verifier;
    fromWorker.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      verifier?._onWorkerMessage(msg);
    });
    final isolate = await Isolate.spawn(
        _verifierWorker, _WorkerConfig(fromWorker.sendPort, layout),
        debugName: 'piece-verifier');
    final toWorker = await ready.future;
    return verifier = IsolatePieceVerifier._(isolate, toWorker, fromWorker);
  }

  void _onWorkerMessage(dynamic msg) {
    if (msg is! List) return;
    final id = msg[0] as int;
    final ok = msg[1] as bool;
    hashMicros += msg[2] as int;
    final pending = _pending.remove(id);
    if (pending == null) return;
    if (ok) {
      verifiedCount++;
    } else {
      failedCount++;
    }
    pending.completer.complete(ok);
  }

  @override
  Future<bool> verifyPiece(int pieceIndex) {
    if (_disposed) return Future.value(false);
    final id = _nextId++;
    final pending = _Pending();
    _pending[id] = pending;
    _toWorker.send([id, pieceIndex]);
    return pending.completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _toWorker.send('close');
    // Незавершённые проверки закрываем как «не сошлось»: задача всё равно
    // останавливается, а повисший Future подвесил бы вызывающего.
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) p.completer.complete(false);
    }
    _pending.clear();
    // Дать изоляту закрыть файловые хэндлы, потом убить безусловно.
    await Future.delayed(const Duration(milliseconds: 50));
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

/// Стартовая посылка в изолят.
class _WorkerConfig {
  final SendPort replyPort;
  final TorrentDiskLayout layout;
  const _WorkerConfig(this.replyPort, this.layout);
}

/// Тело изолята: `[id, pieceIndex]` -> `[id, ok, microseconds]`.
Future<void> _verifierWorker(_WorkerConfig config) async {
  final commands = ReceivePort();
  config.replyPort.send(commands.sendPort);
  final handles = ReadHandleCache();
  await for (final msg in commands) {
    if (msg == 'close') break;
    if (msg is! List) continue;
    final id = msg[0] as int;
    final pieceIndex = msg[1] as int;
    final sw = Stopwatch()..start();
    var ok = false;
    try {
      ok = await verifyPieceOnDisk(config.layout, pieceIndex, handles.handleFor);
    } catch (_) {
      // Любая ошибка чтения — кусок не подтверждён; он вернётся в очередь
      // докачки, а не проскочит в bitfield.
      ok = false;
    }
    sw.stop();
    config.replyPort.send([id, ok, sw.elapsedMicroseconds]);
  }
  await handles.close();
  commands.close();
}
