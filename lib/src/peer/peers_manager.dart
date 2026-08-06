import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:torrent_model/torrent_model.dart';
import 'package:dartorrent_common/dartorrent_common.dart';

import 'bitfield.dart';
import 'peer.dart';
import '../file/download_file_manager.dart';
import '../piece/piece_manager.dart';
import '../piece/piece.dart';
import '../piece/piece_provider.dart';
import '../utils.dart';
import '../peer/pex.dart';
import '../peer/holepunch.dart';

const MAX_ACTIVE_PEERS = 50;

/// Сколько входящих соединений держим одновременно суммарно.
const MAX_IN_PEERS = 10;

/// Сколько входящих соединений допускаем с одного IP.
///
/// Было ровно одно («目前只允许一个ip连一次»), и это резало самый частый случай
/// раздачи: два устройства за одним NAT (а у мобильных операторов — за одним
/// CGNAT) приходят к нам с одного адреса, и второму мы отказывали. Лимит нужен
/// как защита от исчерпания слотов одним источником, а не как запрет NAT.
const MAX_IN_PEERS_PER_IP = 3;

const MAX_WRITE_BUFFER_SIZE = 10 * 1024 * 1024;

/// Сколько несошедшихся по SHA1 кусков прощаем пиру, прежде чем отключить его
/// насовсем.
///
/// Не единица: кусок собирается из блоков нескольких пиров, и «виновником»
/// может быть назначен честный сосед. Три подряд — уже система, а не совпадение.
const MAX_BAD_PIECES_PER_PEER = 3;

const MAX_UPLOADED_NOTIFY_SIZE = 1024 * 1024 * 10; // 10 mb

///
/// TODO:
/// - 没有处理对外的Suggest Piece/Fast Allow
/// Учёт неудачных исходящих подключений к одному адресу.
class _RetryRecord {
  int attempts = 0;
  DateTime nextAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
}

/// Кто виноват в битом куске: [contributions] — сколько блоков этого куска
/// прислал каждый пир.
///
/// Виновным считаем пира, приславшего БОЛЬШЕ ПОЛОВИНЫ блоков: точнее по хэшу
/// целого куска не скажешь — какой именно блок приехал битым, неизвестно. Если
/// кусок собирали вскладчину и явного большинства нет, не наказываем никого:
/// ложный бан честного сида дороже одного лишнего перекачивания куска.
///
/// Ровно половина (2 пира по половине блоков) — это НЕ большинство: наказания
/// не будет.
String? blameForBadPiece(Map<String, int> contributions) {
  if (contributions.isEmpty) return null;
  var total = contributions.values.fold(0, (a, b) => a + b);
  String? best;
  var bestCount = 0;
  contributions.forEach((id, count) {
    if (count > bestCount) {
      bestCount = count;
      best = id;
    }
  });
  if (bestCount * 2 <= total) return null;
  return best;
}

class PeersManager with Holepunch, PEX {
  final List<InternetAddress> IGNORE_IPS = [
    InternetAddress.tryParse('0.0.0.0')!,
    InternetAddress.tryParse('127.0.0.1')!
  ];

  bool _disposed = false;

  bool get isDisposed => _disposed;

  final Set<Peer> _activePeers = {};

  final Set<CompactAddress> _peersAddress = {};

  /// Сколько входящих соединений сейчас держит каждый IP. Счётчик уменьшается
  /// в [_processPeerDispose], поэтому слот освобождается при обрыве.
  final Map<InternetAddress, int> _incomingAddress = {};

  /// Учёт неудачных исходящих подключений: адрес -> сколько попыток подряд
  /// провалилось и когда можно пробовать снова.
  final Map<CompactAddress, _RetryRecord> _retryRecords = {};

  final Set<Timer> _reconnectTimers = {};

  /// Стартовая пауза перед повторным подключением к отвалившемуся адресу;
  /// дальше удваивается до [reconnectMaxDelay]. Поле, а не константа: тесты
  /// сжимают паузу, приложение может её подстроить.
  Duration reconnectBaseDelay = const Duration(seconds: 15);

  Duration reconnectMaxDelay = const Duration(minutes: 5);

  /// Сколько неудач подряд по одному адресу прежде чем перестать пробовать
  /// самим.
  int maxReconnectAttempts = 5;

  /// Порог битых кусков на пира. Поле, а не константа: тесты и приложение
  /// вправе его подстроить.
  int maxBadPieces = MAX_BAD_PIECES_PER_PEER;

  /// Кто прислал какие под-куски незавершённого куска:
  /// `индекс куска -> (ключ источника -> сколько блоков от него)`.
  ///
  /// Ключ источника — [_blameKey], а НЕ `peer.id`: см. его док.
  /// Заполняется в [_processReceivePiece] и живёт ровно до вердикта по куску.
  final Map<int, Map<String, int>> _pieceContributions = {};

  /// Сколько раз источник оказывался виновником несошедшегося куска
  /// (по [_blameKey]).
  final Map<String, int> _badPieceCounts = {};

  /// Источники, отключённые за битые данные (по [_blameKey]). Проверяется на
  /// рукопожатии: соединение забаненного клиента закрывается сразу.
  final Set<String> _bannedPeerIds = {};

  /// Адреса забаненных источников (`адрес:порт` в compact-виде) — чтобы не
  /// набирать их снова по трекеру/DHT/LSD/PEX и не принимать входящие.
  final Set<String> _bannedAddresses = {};

  /// Диагностика/тесты: сколько кусков забраковала рантайм-проверка SHA1.
  int corruptedPiecesCount = 0;

  /// Диагностика/тесты: кого мы отключили за битые куски.
  Set<String> get bannedPeerIds => Set.unmodifiable(_bannedPeerIds);

  int badPieceCountOf(String peerId) => _badPieceCounts[peerId] ?? 0;

  ///
  /// Устойчивый ключ источника для учёта вклада в кусок и наказаний.
  ///
  /// Берём BitTorrent peer_id из рукопожатия, а не `адрес:порт`. Один и тот же
  /// клиент держит с нами НЕСКОЛЬКО соединений (наше исходящее на его
  /// слушающий порт + его входящее с эфемерного порта, принесённое LSD/PEX), и
  /// по адресу это выглядит как разные пиры: вклад в кусок делится между ними
  /// пополам, большинства нет, виновника нет — на живом прогоне это давало
  /// вечную перекачку одного куска (31894 брака за две минуты) и бан честного
  /// сида вместо битого.
  ///
  /// До рукопожатия блоки не ходят, так что при учёте вклада peer_id уже есть;
  /// запасной вариант с адресом оставлен на всякий случай.
  String _blameKey(Peer peer) => peer.remotePeerIdOrNull ?? peer.id!;

  InternetAddress? localExtenelIP;

  /// 写入磁盘的缓存最大值
  int maxWriteBufferSize;

  final _flushIndicesBuffer = <int>{};

  final Set<void Function()> _allcompletehandles = {};

  final Set<void Function()> _noActivePeerhandles = {};

  final Torrent _metaInfo;

  int _uploaded = 0;

  int _downloaded = 0;

  int? _startedTime;

  int? _endTime;

  int _uploadedNotifySize = 0;

  final List<List> _remoteRequest = [];

  final DownloadFileManager _fileManager;

  final PieceProvider _pieceProvider;

  final PieceManager _pieceManager;

  bool _paused = false;

  Timer? _keepAliveTimer;

  final List _pausedRequest = [];

  final Map<String, List> _pausedRemoteRequest = {};

  final String _localPeerId;

  /// Наш слушающий TCP-порт — уходит каждому пиру в extended handshake (BEP 10,
  /// поле `p`), чтобы к нам могли подключиться в ответ и рассказать о нас через
  /// PEX. 0 = неизвестен.
  final int localPort;

  PeersManager(this._localPeerId, this._pieceManager, this._pieceProvider,
      this._fileManager, this._metaInfo,
      [this.maxWriteBufferSize = MAX_WRITE_BUFFER_SIZE, this.localPort = 0]) {
    // hook FileManager and PieceManager
    _fileManager.onSubPieceWriteComplete(_processSubPieceWriteComplte);
    _fileManager.onSubPieceWriteFailed(_processSubPieceWriteFailed);
    _fileManager.onSubPieceReadComplete(readSubPieceComplete);
    _pieceManager.onPieceComplete(_processPieceWriteComplete);
    _pieceManager.onPieceVerifyFailed(_processPieceVerifyFailed);

    // Start pex interval
    startPEX();
  }

  /// Task is paused
  bool get isPaused => _paused;

  /// All peers number. Include the connecting peer.
  int get peersNumber {
    if (_peersAddress.isEmpty) return 0;
    return _peersAddress.length;
  }

  /// All connected peers number. Include seeder.
  int get connectedPeersNumber {
    if (_activePeers.isEmpty) return 0;
    return _activePeers.length;
  }

  /// All seeder number
  int get seederNumber {
    if (_activePeers.isEmpty) return 0;
    var c = 0;
    return _activePeers.fold(c, (previousValue, element) {
      if (element.isSeeder) {
        return previousValue + 1;
      }
      return previousValue;
    });
  }

  /// Since first peer connected to end time ,
  ///
  /// The end time is current, but once `dispose` this class
  /// the end time is when manager was disposed.
  int get liveTime {
    if (_startedTime == null) return 0;
    var passed = DateTime.now().millisecondsSinceEpoch - _startedTime!;
    if (_endTime != null) {
      passed = _endTime! - _startedTime!;
    }
    return passed;
  }

  /// Average download speed , b/ms
  ///
  /// This speed caculation : `total download content bytes` / [liveTime]
  double get averageDownloadSpeed {
    var live = liveTime;
    if (live == 0) return 0.0;
    return _downloaded / live;
  }

  /// Average upload speed , b/ms
  ///
  /// This speed caculation : `total upload content bytes` / [liveTime]
  double get averageUploadSpeed {
    var live = liveTime;
    if (live == 0) return 0.0;
    return _uploaded / live;
  }

  /// Current download speed , b/ms
  ///
  /// This speed caculation: sum(`active peer download speed`)
  double get currentDownloadSpeed {
    if (_activePeers.isEmpty) return 0.0;
    return _activePeers.fold(
        0.0, (p, element) => p + element.currentDownloadSpeed);
  }

  /// Current upload speed , b/ms
  ///
  /// This speed caculation: sum(`active peer upload speed`)
  double get uploadSpeed {
    if (_activePeers.isEmpty) return 0.0;
    return _activePeers.fold(
        0.0, (p, element) => p + element.averageUploadSpeed);
  }

  void _hookPeer(Peer peer) {
    if (peer.address.address == localExtenelIP) return;
    if (_peerExsist(peer)) return;
    peer.onDispose(_processPeerDispose);
    peer.onBitfield(_processBitfieldUpdate);
    peer.onHaveAll(_processHaveAll);
    peer.onHaveNone(_processHaveNone);
    peer.onHandShake(_processPeerHandshake);
    peer.onChokeChange(_processChokeChange);
    peer.onInterestedChange(_processInterestedChange);
    peer.onConnect(_peerConnected);
    peer.onHave(_processHaveUpdate);
    peer.onPiece(_processReceivePiece);
    peer.onRequest(_processRemoteRequest);
    peer.onRequestTimeout(_processRequestTimeout);
    peer.onSuggestPiece(_processSuggestPiece);
    peer.onRejectRequest(_processRejectRequest);
    peer.onAllowFast(_processAllowFast);
    peer.onExtendedEvent(_processExtendedMessage);
    _registerExtended(peer);
    peer.connect();
  }

  /// 支持哪些扩展在这里添加
  void _registerExtended(Peer peer) {
    peer.registerExtened('ut_pex');
    peer.registerExtened('ut_holepunch');
  }

  void unHookPeer(Peer peer) {
    peer.offDispose(_processPeerDispose);
    peer.offBitfield(_processBitfieldUpdate);
    peer.offHaveAll(_processHaveAll);
    peer.offHaveNone(_processHaveNone);
    peer.offHandShake(_processPeerHandshake);
    peer.offChokeChange(_processChokeChange);
    peer.offInterestedChange(_processInterestedChange);
    peer.offConnect(_peerConnected);
    peer.offHave(_processHaveUpdate);
    peer.offPiece(_processReceivePiece);
    peer.offRequest(_processRemoteRequest);
    peer.offRequestTimeout(_processRequestTimeout);
    peer.offRejectRequest(_processRejectRequest);
    peer.offAllowFast(_processAllowFast);
    peer.offExtendedEvent(_processExtendedMessage);
  }

  bool _peerExsist(Peer id) {
    return _activePeers.contains(id);
  }

  void _processExtendedMessage(dynamic source, String name, dynamic data) {
    if (name == 'ut_holepunch') {
      parseHolepuchMessage(data);
    }
    if (name == 'ut_pex') {
      parsePEXDatas(source, data);
    }
    if (name == 'handshake') {
      if (localExtenelIP != null &&
          data['yourip'] != null &&
          (data['yourip'].length == 4 || data['yourip'].length == 16)) {
        InternetAddress myip;
        try {
          myip = InternetAddress.fromRawAddress(data['yourip']);
        } catch (e) {
          return;
        }
        if (IGNORE_IPS.contains(myip)) return;
        localExtenelIP = InternetAddress.fromRawAddress(data['yourip']);
      }
    }
  }

  /// Add a new peer [address] , the default [type] is `PeerType.TCP`,
  /// [socket] is null.
  ///
  /// Usually [socket] is null , unless this peer was incoming connection, but
  /// this type peer was managed by [TorrentTask] , user don't need to know that.
  void addNewPeerAddress(CompactAddress address,
      [PeerType type = PeerType.TCP, Socket? socket]) {
    if (address.address == localExtenelIP) {
      socket?.close();
      return;
    }
    // Отключённый за битые куски не возвращается ни сам, ни через
    // трекер/DHT/LSD/PEX: иначе один сид с испорченной копией книги кормил бы
    // нас мусором бесконечно.
    if (_bannedAddresses.contains(address.toContactEncodingString())) {
      socket?.close();
      return;
    }
    if (socket != null) {
      // 说明是主动连接的peer,目前只允许一个ip连一次
      //
      // Слот освобождается в [_processPeerDispose], поэтому после разрыва тот
      // же адрес может подключиться снова. Раньше этот учёт (по факту —
      // сломанный, см. `_hookInPeer`) жил в TorrentTask и не освобождался
      // никогда.
      var total = _incomingAddress.values.fold(0, (a, b) => a + b);
      var fromThisIp = _incomingAddress[address.address] ?? 0;
      if (total >= MAX_IN_PEERS || fromThisIp >= MAX_IN_PEERS_PER_IP) {
        socket.close();
        return;
      }
      _incomingAddress[address.address] = fromThisIp + 1;
    } else if (!_mayDialOutTo(address)) {
      // Исходящее подключение к адресу, который недавно отвалился, — придержим
      // до истечения паузы. На входящие это правило не распространяется: это не
      // наша попытка, и отказ от неё убил бы раздачу.
      return;
    }
    if (_peersAddress.add(address)) {
      Peer? peer;
      if (type == PeerType.TCP) {
        peer = Peer.newTCPPeer(_localPeerId, address, _metaInfo.infoHashBuffer!,
            _metaInfo.pieces.length, socket,
            localPort: localPort);
      }
      if (type == PeerType.UTP) {
        peer = Peer.newUTPPeer(_localPeerId, address, _metaInfo.infoHashBuffer!,
            _metaInfo.pieces.length, socket,
            localPort: localPort);
      }
      if (peer != null) _hookPeer(peer);
    } else {
      // Адрес уже обслуживается — дублирующий сокет закрываем, а не роняем.
      socket?.close();
    }
  }

  /// Можно ли прямо сейчас инициировать исходящее подключение к [address].
  bool _mayDialOutTo(CompactAddress address) {
    var record = _retryRecords[address];
    if (record == null) return true;
    if (DateTime.now().isBefore(record.nextAttemptAt)) return false;
    // Пауза выдержана — счётчик попыток обнуляем, адрес снова «свежий».
    _retryRecords.remove(address);
    return true;
  }

  /// Запланировать повторное подключение к отвалившемуся пиру.
  ///
  /// Раньше `_processPeerDispose` звал `addNewPeerAddress` немедленно и без
  /// ограничений: пир, рвущий соединение сразу после handshake, крутил нас в
  /// плотном цикле переподключений. Пауза растёт экспоненциально от
  /// [reconnectBaseDelay] до [reconnectMaxDelay], после
  /// [maxReconnectAttempts] неудач подряд свои попытки прекращаем — адрес
  /// вернётся, только если его снова принесут трекер/DHT/LSD/PEX, и то не
  /// раньше конца паузы.
  void _scheduleReconnect(CompactAddress address, PeerType type) {
    if (isDisposed) return;
    var record = _retryRecords.putIfAbsent(address, () => _RetryRecord());
    record.attempts++;
    var delay = reconnectBaseDelay * (1 << (record.attempts - 1));
    if (delay > reconnectMaxDelay) delay = reconnectMaxDelay;
    record.nextAttemptAt = DateTime.now().add(delay);
    if (record.attempts > maxReconnectAttempts) return;
    late Timer timer;
    timer = Timer(delay, () {
      _reconnectTimers.remove(timer);
      if (isDisposed) return;
      addNewPeerAddress(address, type);
    });
    _reconnectTimers.add(timer);
  }

  void _processSubPieceWriteComplte(int pieceIndex, int begin, int length) {
    _pieceManager.processSubPieceWriteComplete(pieceIndex, begin, length);
  }

  /// Запись под-piece на диск провалилась (файл занят/нет места/нет прав, либо
  /// piece не отображается ни в один файл).
  ///
  /// Сеть подтвердила запрос ещё ДО записи (`ackRequest` в
  /// `Peer._processReceivePieces`), поэтому сам по себе блок никто не
  /// перезапросит: без этого обработчика под-piece оставался в
  /// `Piece._writtingSubPieces` навсегда, и загрузка замирала у самого финиша.
  ///
  /// Возвращаем под-piece в очередь и будим спящих пиров — иначе, если в полёте
  /// не осталось ни одного запроса, `_requestPieces` никем не будет вызван и
  /// вернувшийся в очередь блок так и не уйдёт в сеть.
  void _processSubPieceWriteFailed(int pieceIndex, int begin, int length) {
    var requeued =
        _pieceManager.processSubPieceWriteFailed(pieceIndex, begin, length);
    log(
      'Запись под-piece ($pieceIndex, $begin, $length) провалилась, '
      '${requeued ? 'возвращён в очередь докачки' : 'возврат не потребовался'}',
      name: runtimeType.toString(),
    );
    if (!requeued) return;
    for (var p in _activePeers) {
      if (p.isSleeping) Timer.run(() => _requestPieces(p));
    }
  }

  /// Кусок собран, но SHA1 не сошёлся.
  ///
  /// К этому моменту `PieceManager` уже вернул все под-куски в очередь докачки.
  /// Наша часть: наказать источник и снова сделать кусок скачиваемым — при
  /// завершении куска `Piece.clearAvalidatePeer` стёр список доступных пиров, и
  /// без восстановления `BasePieceSelector` этот кусок больше никому не выдаст
  /// (он требует `containsAvalidatePeer`), а загрузка встанет навсегда.
  void _processPieceVerifyFailed(int index) {
    corruptedPiecesCount++;
    var contributions = _pieceContributions.remove(index) ?? const {};
    var culprit = blameForBadPiece(contributions);
    log(
      'Кусок $index не сошёлся с SHA1 (вклад пиров: $contributions), '
      '${culprit == null ? 'виновник не определён' : 'виновник $culprit'}',
      name: runtimeType.toString(),
    );
    if (culprit != null) _punishForBadPiece(culprit);

    var piece = _pieceProvider[index];
    if (piece == null) return;
    var candidates = <Peer>[];
    for (var peer in _activePeers) {
      if (peer.isDisposed || peer.chokeMe) continue;
      if (!peer.remoteHave(index)) continue;
      if (_bannedPeerIds.contains(_blameKey(peer))) continue;
      candidates.add(peer);
    }
    if (candidates.isEmpty) return;

    if (culprit == null && contributions.length > 1 && candidates.length > 1) {
      // Кусок собирали вскладчину и виноватого не видно. Перекачиваем его
      // ЦЕЛИКОМ у ОДНОГО пира: иначе следующая попытка снова соберётся из
      // блоков нескольких источников, вердикт снова окажется «большинства
      // нет», и мы будем бесконечно качать один и тот же кусок, никого не
      // наказывая (ровно так это и выглядело на прогоне: 31894 брака за две
      // минуты и ни одного бана).
      //
      // Берём самого крупного вкладчика в провалившуюся попытку: если битые
      // байты его, следующий провал будет адресным; если нет — кусок просто
      // сойдётся.
      var exclusive = _largestContributorAmong(candidates, contributions);
      piece.restrictToPeer(exclusive.id!);
      log(
        'Кусок $index перекачиваем эксклюзивно у ${exclusive.id} — '
        'вердикт по прошлой попытке был неадресным',
        name: runtimeType.toString(),
      );
    } else {
      for (var peer in candidates) {
        piece.addAvalidatePeer(peer.id!);
      }
    }
    _pieceManager.processDownloadingPiece(index);
    for (var peer in _activePeers) {
      if (peer.isSleeping) Timer.run(() => _requestPieces(peer, index));
    }
  }

  ///
  /// Раздать «осиротевшим» кускам доступных пиров заново.
  ///
  /// Кусок, у которого не осталось ни одного доступного пира, больше никем не
  /// будет выбран: [BasePieceSelector] требует `containsAvalidatePeer`, а
  /// список чистится при уходе пира (и при бане за битые куски). На живом
  /// прогоне это выглядело так: битый сид забанен — и последний кусок, который
  /// был только у него, навсегда остался недокачанным, хотя рядом был честный
  /// сид с теми же данными.
  void _rearmOrphanPieces() {
    for (var peer in _activePeers) {
      if (peer.isDisposed || peer.chokeMe) continue;
      if (_bannedPeerIds.contains(_blameKey(peer))) continue;
      for (var index in peer.remoteCompletePieces) {
        var piece = _pieceProvider[index];
        if (piece == null) continue;
        if (piece.avalidatePeersCount > 0) continue;
        if (!piece.haveAvalidateSubPiece()) continue;
        piece.addAvalidatePeer(peer.id!);
      }
    }
    // Будим спящих ВСЕГДА, а не только когда список доступных пиров изменился:
    // ушедший пир унёс с собой запросы, и оставшаяся работа лежит в очереди
    // куска, а просить её некому — `_requestPieces` вызывается только по
    // приходу блока или по такому вот пинку. На живом прогоне это выглядело
    // как вечный простой на последнем куске при двух живых сидах.
    for (var peer in _activePeers) {
      if (peer.isSleeping) Timer.run(() => _requestPieces(peer));
    }
  }

  /// Самый крупный вкладчик провалившейся попытки среди [candidates]; если
  /// никто из них в ней не участвовал — первый доступный.
  Peer _largestContributorAmong(
      List<Peer> candidates, Map<String, int> contributions) {
    Peer? best;
    var bestCount = -1;
    for (var peer in candidates) {
      var count = contributions[_blameKey(peer)] ?? 0;
      if (count > bestCount) {
        bestCount = count;
        best = peer;
      }
    }
    return best ?? candidates.first;
  }

  /// Отключить пира, если он перебрал лимит битых кусков.
  void _punishForBadPiece(String peerId) {
    var count = (_badPieceCounts[peerId] ?? 0) + 1;
    _badPieceCounts[peerId] = count;
    if (count < maxBadPieces) {
      log('Пир $peerId прислал битый кусок ($count/$maxBadPieces)',
          name: runtimeType.toString());
      return;
    }
    _bannedPeerIds.add(peerId);
    log('Источник $peerId отключён навсегда: $count битых кусков',
        name: runtimeType.toString());
    // Рвём ВСЕ соединения этого клиента (их обычно два — наше исходящее и его
    // входящее) и запоминаем их адреса, чтобы не набрать их заново.
    for (var peer in _activePeers.toList()) {
      if (_blameKey(peer) != peerId) continue;
      var contact = peer.address.toContactEncodingString();
      if (contact != null) _bannedAddresses.add(contact);
      Timer.run(() => peer.dispose(
          BadException('Отключён за $count несошедшихся по SHA1 кусков')));
    }
  }

  void _processPieceWriteComplete(int index) async {
    _pieceContributions.remove(index);
    if (_fileManager.localHave(index)) return;
    await _fileManager.updateBitfield(index);
    for (var peer in _activePeers) {
      // if (!peer.remoteHave(index)) {
      peer.sendHave(index);
      // }
    }
    _flushIndicesBuffer.add(index);
    if (_fileManager.isAllComplete) {
      await _flushFiles(_flushIndicesBuffer);
      _fireAllComplete();
    } else {
      await _flushFiles(_flushIndicesBuffer);
    }
  }

  Future _flushFiles(final Set<int> indices) async {
    if (indices.isEmpty) return;
    var piecesSize = _metaInfo.pieceLength;
    var buffer = indices.length * piecesSize!;
    if (buffer >= maxWriteBufferSize || _fileManager.isAllComplete) {
      var temp = Set<int>.from(indices);
      indices.clear();
      await _fileManager.flushFiles(temp);
    }
    return;
  }

  void _fireAllComplete() {
    for (var element in _allcompletehandles) {
      Timer.run(() => element());
    }
  }

  bool onAllComplete(void Function() h) {
    return _allcompletehandles.add(h);
  }

  bool offAllComplete(void Function() h) {
    return _allcompletehandles.remove(h);
  }

  /// When read the resource content complete , invoke this method to notify
  /// this class to send it to related peer.
  ///
  /// [pieceIndex] is the index of the piece, [begin] is the byte index of the whole
  /// contents , [block] should be uint8 list, it's the sub-piece contents bytes.
  void readSubPieceComplete(int pieceIndex, int begin, List<int> block) {
    var dindex = [];
    for (var i = 0; i < _remoteRequest.length; i++) {
      var request = _remoteRequest[i];
      if (request[0] == pieceIndex && request[1] == begin) {
        dindex.add(i);
        var peer = request[2] as Peer;
        if (!peer.isDisposed) {
          if (peer.sendPiece(pieceIndex, begin, block)) {
            _uploaded += block.length;
            _uploadedNotifySize += block.length;
          }
        }
        break;
      }
    }
    if (dindex.isNotEmpty) {
      for (var i in dindex) {
        _remoteRequest.removeAt(i);
      }
      if (_uploadedNotifySize >= MAX_UPLOADED_NOTIFY_SIZE) {
        _uploadedNotifySize = 0;
        _fileManager.updateUpload(_uploaded);
      }
    }
  }

  /// 即使对方choke了我，也可以下载
  void _processAllowFast(dynamic source, int index) {
    var peer = source as Peer;
    var piece = _pieceProvider[index];
    if (piece != null && piece.haveAvalidateSubPiece()) {
      piece.addAvalidatePeer(peer.id!);
      _pieceManager.processDownloadingPiece(index);
      _requestPieces(source, index);
    }
  }

  void _processSuggestPiece(dynamic source, int index) {}

  void _processRejectRequest(dynamic source, int index, int begin, int length) {
    var piece = _pieceProvider[index];
    piece?.pushSubPieceLast(begin ~/ DEFAULT_REQUEST_LENGTH);
  }

  void _pushSubpicesBack(List<List<int>> requests) {
    if (requests.isEmpty) return;
    for (var element in requests) {
      var pindex = element[0];
      var begin = element[1];
      // TODO 这里很危险，目前都是已16kb来分解一个piece，如果不是呢？
      var piece = _pieceManager[pindex];
      var subindex = begin ~/ DEFAULT_REQUEST_LENGTH;
      piece?.pushSubPiece(subindex);
    }
  }

  void _processPeerDispose(dynamic source, [dynamic reason]) {
    var peer = source as Peer;
    var reconnect = true;
    if (reason is BadException) {
      reconnect = false;
    }

    _peersAddress.remove(peer.address);
    if (peer.incoming) {
      var left = (_incomingAddress[peer.address.address] ?? 1) - 1;
      if (left <= 0) {
        _incomingAddress.remove(peer.address.address);
      } else {
        _incomingAddress[peer.address.address] = left;
      }
    }
    _activePeers.remove(peer);

    var bufferRequests = peer.requestBuffer;
    _pushSubpicesBack(bufferRequests);

    var completedPieces = peer.remoteCompletePieces;
    for (var index in completedPieces) {
      _pieceProvider[index]?.removeAvalidatePeer(peer.id!);
    }
    // Ушедший пир мог быть последним источником своих кусков — раздаём их
    // оставшимся, иначе загрузка встанет на них навсегда.
    _rearmOrphanPieces();
    _pausedRemoteRequest.remove(peer.id);
    var tempIndex = [];
    for (var i = 0; i < _pausedRequest.length; i++) {
      var pr = _pausedRequest[i];
      if (pr[0] == peer) {
        tempIndex.add(i);
      }
    }
    for (var index in tempIndex) {
      _pausedRequest.removeAt(index);
    }

    // Забанен за битые куски — никаких переподключений, в том числе по ветке
    // «сеятель, а мы ещё не докачали» ниже.
    if (_bannedPeerIds.contains(_blameKey(peer))) return;

    if (reason is TCPConnectException) {
      // Адрес не отвечает. Своих попыток не планируем, но фиксируем неудачу:
      // если тот же адрес принесёт трекер/DHT, мы не побежим к нему сразу.
      _noteFailedDial(peer.address);
      return;
    }

    // К входящему подключению обратно не стучимся: в его адресе стоит
    // эфемерный порт источника, а не слушающий порт пира — соединение туда
    // заведомо некуда. Такой пир вернётся сам.
    if (peer.incoming) return;

    if (reconnect) {
      if (_activePeers.length < MAX_ACTIVE_PEERS && !isDisposed) {
        _scheduleReconnect(peer.address, peer.type);
      }
    } else {
      if (peer.isSeeder && !_fileManager.isAllComplete && !isDisposed) {
        _scheduleReconnect(peer.address, peer.type);
      }
    }
  }

  /// Отметить неудачную попытку исходящего подключения, ничего не планируя.
  void _noteFailedDial(CompactAddress address) {
    var record = _retryRecords.putIfAbsent(address, () => _RetryRecord());
    record.attempts++;
    var delay = reconnectBaseDelay * (1 << (record.attempts - 1));
    if (delay > reconnectMaxDelay) delay = reconnectMaxDelay;
    record.nextAttemptAt = DateTime.now().add(delay);
  }

  void _peerConnected(dynamic source) {
    _startedTime ??= DateTime.now().millisecondsSinceEpoch;
    _endTime = null;
    var peer = source as Peer;
    // Связь установлена — история неудач по этому адресу больше не актуальна.
    _retryRecords.remove(peer.address);
    _activePeers.add(peer);
    peer.sendHandShake();
  }

  void _requestPieces(dynamic source, [int pieceIndex = -1]) async {
    if (isPaused) {
      _pausedRequest.add([source, pieceIndex]);
      return;
    }
    var peer = source as Peer;
    // Выброшенному пиру запрос отдавать нельзя: `sendRequest` всё равно
    // положит его в буфер уже мёртвого соединения и вернёт `true`, под-кусок
    // уйдёт из очереди и не вернётся никогда (`_pushSubpicesBack` для этого
    // пира уже отработал в момент dispose). Нас сюда зовут через `Timer.run`,
    // так что пир вполне может умереть между постановкой задачи и её
    // выполнением — например, когда мы сами только что забанили его за битые
    // куски. На живом прогоне это и был вечный простой на последнем куске:
    // один под-кусок «завис» у выброшенного пира.
    if (peer.isDisposed) return;

    Piece? piece;
    if (pieceIndex != -1 && _pieceProvider[pieceIndex] != null) {
      piece = _pieceProvider[pieceIndex];
      // Продолжать «свой» кусок можно, только если он не отдан в единоличную
      // перекачку другому пиру. Эта ветка идёт мимо `selectPiece` и мимо
      // проверки доступных пиров — без явного условия она сводила на нет любое
      // ограничение источника: оба соединения с битым сидом продолжали
      // подливать блоки в один и тот же кусок, и вердикт «кто виноват» вечно
      // оставался неопределённым.
      if (!piece!.allowsPeer(peer.id!)) {
        piece = _pieceManager.selectPiece(peer.id!, peer.remoteCompletePieces,
            _pieceProvider, peer.remoteSuggestPieces);
      } else if (!piece.haveAvalidateSubPiece()) {
        piece = _pieceManager.selectPiece(peer.id!, peer.remoteCompletePieces,
            _pieceProvider, peer.remoteSuggestPieces);
      }
    } else {
      piece = _pieceManager.selectPiece(peer.id!, peer.remoteCompletePieces,
          _pieceProvider, peer.remoteSuggestPieces);
    }
    if (piece == null) return;

    var subIndex = piece.popSubPiece();
    var size = DEFAULT_REQUEST_LENGTH; // block大小现算
    var begin = subIndex! * size;
    if ((begin + size) > piece.byteLength!) {
      size = piece.byteLength! - begin;
    }
    if (!peer.sendRequest(piece.index!, begin, size)) {
      piece.pushSubPiece(subIndex);
    } else {
      Timer.run(() => _requestPieces(peer, pieceIndex));
    }
  }

  void _processReceivePiece(
      dynamic source, int index, int begin, List<int> block) {
    var peer = source as Peer;
    _downloaded += block.length;

    var piece = _pieceManager[index];
    if (piece != null) {
      var i = index;
      // Кто прислал этот блок — понадобится, если кусок не сойдётся с SHA1.
      //
      // Учёт огрублённый: считаем блоки на пира, а не помним источник каждого
      // под-куска отдельно. Один и тот же под-piece, приехавший дважды (после
      // таймаута/reject'а), учитывается обоим отправителям. Точной трассировки
      // «этот байт от того пира» протокол всё равно не даёт: хэш ломается на
      // куске целиком.
      var contributions =
          _pieceContributions.putIfAbsent(i, () => <String, int>{});
      var key = _blameKey(peer);
      contributions[key] = (contributions[key] ?? 0) + 1;
      Timer.run(() => _fileManager.writeFile(i, begin, block));
      piece.subPieceDownloadComplete(begin);
      if (piece.haveAvalidateSubPiece()) index = -1;
    }
    Timer.run(() => _requestPieces(peer, index));
  }

  void _processPeerHandshake(dynamic source, String remotePeerId, data) {
    var peer = source as Peer;
    // Забаненный за битые куски клиент мог прийти с другого порта — узнаём его
    // по peer_id и закрываемся сразу, до обмена данными.
    if (_bannedPeerIds.contains(remotePeerId)) {
      var contact = peer.address.toContactEncodingString();
      if (contact != null) _bannedAddresses.add(contact);
      Timer.run(() =>
          peer.dispose(BadException('Отключён ранее за битые куски')));
      return;
    }
    peer.sendBitfield(_fileManager.localBitfield);
  }

  void _processRemoteRequest(dynamic source, int index, int begin, int length) {
    if (isPaused) {
      var peer = source as Peer;
      _pausedRemoteRequest[peer.id!] ??= [];
      var pausedRequest = _pausedRemoteRequest[peer.id];
      pausedRequest!.add([source, index, begin, length]);
      return;
    }
    var peer = source as Peer;
    _remoteRequest.add([index, begin, peer]);
    _fileManager.readFile(index, begin, length);
  }

  void _processHaveAll(dynamic source) {
    var peer = source as Peer;
    _processBitfieldUpdate(source, peer.remoteBitfield);
  }

  void _processHaveNone(dynamic source) {
    _processBitfieldUpdate(source, null);
  }

  void _processBitfieldUpdate(dynamic source, Bitfield? bitfield) {
    var peer = source as Peer;
    if (bitfield != null) {
      if (peer.interestedRemote) return;
      if (_fileManager.isAllComplete && peer.isSeeder) {
        peer.dispose(BadException('已经下载完成不再连接Seeder'));
        return;
      }
      for (var i = 0; i < _fileManager.piecesNumber; i++) {
        if (bitfield.getBit(i)) {
          if (!peer.interestedRemote && !_fileManager.localHave(i)) {
            peer.sendInterested(true);
            return;
          }
        }
      }
    }
    peer.sendInterested(false);
  }

  void _processHaveUpdate(dynamic source, List<int> indices) {
    var peer = source as Peer;
    var flag = false;
    for (var index in indices) {
      if (_pieceProvider[index] == null) continue;

      if (!_fileManager.localHave(index)) {
        if (peer.chokeMe) {
          peer.sendInterested(true);
        } else {
          flag = true;
          _pieceProvider[index]?.addAvalidatePeer(peer.id!);
        }
      }
    }
    if (flag && peer.isSleeping) Timer.run(() => _requestPieces(peer));
  }

  void _processChokeChange(dynamic source, bool choke) {
    var peer = source as Peer;
    // 更新pieces的可用Peer
    if (!choke) {
      var completedPieces = peer.remoteCompletePieces;
      for (var index in completedPieces) {
        _pieceProvider[index]?.addAvalidatePeer(peer.id!);
      }
      // 这里开始通知request;
      Timer.run(() => _requestPieces(peer));
    } else {
      var completedPieces = peer.remoteCompletePieces;
      for (var index in completedPieces) {
        _pieceProvider[index]?.removeAvalidatePeer(peer.id!);
      }
    }
  }

  void _processInterestedChange(dynamic source, bool interested) {
    var peer = source as Peer;
    if (interested) {
      peer.sendChoke(false);
    } else {
      peer.sendChoke(true); // 不感兴趣就choke它
    }
  }

  void _processRequestTimeout(dynamic source, List<List<int>> requests) {
    var peer = source as Peer;
    var flag = false;
    for (var element in requests) {
      if (element[4] >= 3) {
        flag = true;
        Timer.run(() => peer.requestCancel(element[0], element[1], element[2]));
        var index = element[0];
        var begin = element[1];
        var subindex = begin ~/ DEFAULT_REQUEST_LENGTH;
        var piece = _pieceManager[index];
        piece?.pushSubPiece(subindex);
      }
    }
    // 唤醒其他可能没有工作的peer
    if (flag) {
      for (var p in _activePeers) {
        if (p != peer && p.isSleeping) {
          Timer.run(() => _requestPieces(p));
        }
      }
    }
  }

  void _sendKeepAliveToAll() {
    for (var peer in _activePeers) {
      Timer.run(() => _keepAlive(peer));
    }
  }

  void _keepAlive(Peer peer) {
    peer.sendKeeplive();
  }

  /// Pause the task
  ///
  /// All the incoming request message will be received but they will be stored
  /// in buffer and no response to remote.
  ///
  /// All out message/incoming connection will be processed even task is paused.
  void pause() {
    if (_paused) return;
    _paused = true;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer(Duration(seconds: 110), _sendKeepAliveToAll);
  }

  /// Resume the task
  void resume() {
    if (!_paused) return;
    _paused = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    for (var element in _pausedRequest) {
      var peer = element[0] as Peer;
      var index = element[1];
      if (!peer.isDisposed) Timer.run(() => _requestPieces(peer, index));
    }
    _pausedRequest.clear();

    _pausedRemoteRequest.forEach((key, value) {
      for (var element in value) {
        var peer = element[0] as Peer;
        var index = element[1];
        var begin = element[2];
        var length = element[3];
        if (!peer.isDisposed) {
          Timer.run(() => _processRemoteRequest(peer, index, begin, length));
        }
      }
    });
    _pausedRemoteRequest.clear();
  }

  Future disposeAllSeeder([dynamic reason]) async {
    // Iterate over a snapshot: dispose() mutates _activePeers via its dispose
    // handler, which would otherwise throw a concurrent-modification error.
    for (var peer in _activePeers.toList()) {
      if (peer.isSeeder) {
        await peer.dispose(reason);
      }
    }
  }

  Future dispose() async {
    if (isDisposed) return;
    _disposed = true;
    clearHolepunch();
    clearPEX();
    _endTime = DateTime.now().millisecondsSinceEpoch;

    _fileManager.offSubPieceWriteComplete(_processSubPieceWriteComplte);
    _fileManager.offSubPieceWriteFailed(_processSubPieceWriteFailed);
    _fileManager.offSubPieceReadComplete(readSubPieceComplete);
    _pieceManager.offPieceComplete(_processPieceWriteComplete);
    _pieceManager.offPieceVerifyFailed(_processPieceVerifyFailed);

    await _flushFiles(_flushIndicesBuffer);
    _flushIndicesBuffer.clear();
    _allcompletehandles.clear();
    _noActivePeerhandles.clear();
    _remoteRequest.clear();
    _pausedRequest.clear();
    _pausedRemoteRequest.clear();
    for (var t in _reconnectTimers) {
      t.cancel();
    }
    _reconnectTimers.clear();
    _retryRecords.clear();
    _pieceContributions.clear();
    _badPieceCounts.clear();
    _bannedPeerIds.clear();
    _bannedAddresses.clear();
    Future<void> disposePeers(Set<Peer> peers) async {
      if (peers.isNotEmpty) {
        for (var i = 0; i < peers.length; i++) {
          var peer = peers.elementAt(i);
          unHookPeer(peer);
          await peer.dispose('Peer Manager disposed');
        }
      }
      peers.clear();
    }
    await disposePeers(_activePeers);
  }

  //TODO test:

  @override
  void addPEXPeer(dynamic source, CompactAddress address, Map options) {
    // addNewPeerAddress(address);
    // return;
    // if (options['reachable'] != null) {
    //   if (options['utp'] != null) {
    //     print('UTP/TCP reachable');
    //   }
    //   addNewPeerAddress(address);
    //   return;
    // }
    if ((options['utp'] != null || options['ut_holepunch'] != null) &&
        options['reachable'] == null) {
      var peer = source as Peer;
      var message = getRendezvousMessage(address);
      peer.sendExtendMessage('ut_holepunch', message as List<int>);
      return;
    }
    addNewPeerAddress(address);
  }

  @override
  Iterable<Peer> get activePeers => _activePeers;

  @override
  void holePunchConnect(CompactAddress ip) {
    addNewPeerAddress(ip, PeerType.UTP);
  }

  int get utpPeerCount {
    return _activePeers.fold(0, (previousValue, element) {
      if (element.type == PeerType.UTP) {
        previousValue += 1;
      }
      return previousValue;
    });
  }

  double get utpDownloadSpeed {
    return _activePeers.fold(0.0, (previousValue, element) {
      if (element.type == PeerType.UTP) {
        previousValue += element.currentDownloadSpeed;
      }
      return previousValue;
    });
  }

  double get utpUploadSpeed {
    return _activePeers.fold(0.0, (previousValue, element) {
      if (element.type == PeerType.UTP) {
        previousValue += element.averageUploadSpeed;
      }
      return previousValue;
    });
  }

  @override
  void holePunchError(String err, CompactAddress ip) {
    // print('holepunch error - $err');
  }

  @override
  void holePunchRendezvous(CompactAddress ip) {
    // TODO: implement holePunchRendezvous
    // print('收到 holePunch Rendezvous');
  }
}
