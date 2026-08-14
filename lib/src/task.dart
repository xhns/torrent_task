import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_tracker/torrent_tracker.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:dht_dart/dht_dart.dart';
import 'package:utp/utp.dart';

import 'file/download_file_manager.dart';
import 'file/piece_layout.dart';
import 'file/piece_verifier.dart';
import 'file/recheck.dart';
import 'file/state_file.dart';
import 'lsd/lsd.dart';
import 'nat/port_mapper.dart';
import 'nat/reachability.dart';
import 'peer/peer.dart';
import 'piece/piece_manager.dart';
import 'piece/piece_selector.dart';
import 'piece/sequential_piece_selector.dart';
import 'peer/peers_manager.dart';
import 'utils.dart';

const MAX_PEERS = 50;

/// Слушающий порт по умолчанию.
///
/// Эфемерный порт (`0`), стоявший здесь раньше, делал клиент принципиально
/// недостижимым: он менялся при каждом запуске, поэтому ни ручной проброс на
/// роутере, ни устойчивый маппинг были невозможны в принципе. 51413 —
/// общепринятый BitTorrent-порт (его же по умолчанию берёт Transmission),
/// поэтому пользователю, пробрасывающему порт руками, не нужно ничего
/// выяснять.
///
/// Приложению правильнее выбрать порт ОДИН РАЗ (например случайный из
/// 49152–65535, чтобы не попадать под шейпинг известного 51413) и хранить его
/// в своих настройках, передавая сюда при каждом запуске: движок хранением не
/// занимается, ему нужен только параметр.
const int kDefaultListenPort = 51413;

/// Значение [kDefaultListenPort]-параметра, означающее «дай любой свободный».
const int kEphemeralListenPort = 0;

abstract class TorrentTask {
  /// [listenPort] — порт, на котором задача слушает входящие TCP и uTP.
  /// [kEphemeralListenPort] (`0`) даёт случайный порт и заведомо недостижимый
  /// снаружи клиент — это осознанный выбор для тестов, не для приложения.
  /// Если порт занят, задача откатывается на эфемерный (см. [reachability]).
  ///
  /// [enableUtp] включает приём входящих uTP на том же номере порта, но по
  /// UDP. [enablePortMapping] разрешает задаче самой пробить порт на роутере
  /// (UPnP IGD / NAT-PMP / PCP).
  ///
  /// [portMapper] позволяет подменить пробиватель порта — нужно тестам, чтобы
  /// не ходить в настоящую сеть.
  ///
  /// [sequential] переводит задачу на ПОСЛЕДОВАТЕЛЬНЫЙ выбор кусков
  /// ([SequentialPieceSelector]) вместо стандартного rarest-first: нужно
  /// режиму «слушать по мере скачивания», где первые файлы обязаны приехать
  /// раньше остальных. По умолчанию `false` — поведение движка не меняется.
  /// [pieceOrder] задаёт желаемый порядок кусков (самый нужный первым) и имеет
  /// смысл только вместе с [sequential]; `null` — естественный порядок
  /// индексов.
  factory TorrentTask.newTask(
    Torrent metaInfo,
    String savePath, {
    int listenPort = kDefaultListenPort,
    bool enableUtp = true,
    bool enablePortMapping = true,
    PortMapper? portMapper,
    bool sequential = false,
    List<int>? pieceOrder,
  }) {
    assert(pieceOrder == null || sequential,
        'pieceOrder без sequential:true ничего не делает');
    return _TorrentTask(metaInfo, savePath,
        listenPort: listenPort,
        enableUtp: enableUtp,
        enablePortMapping: enablePortMapping,
        portMapper: portMapper,
        sequential: sequential,
        pieceOrder: pieceOrder);
  }
  void startAnnounceUrl(Uri url, Uint8List infoHash);

  /// Достижима ли наша раздача извне: слушающий порт, внешние адрес/порт и
  /// способ, которым они получены, и сколько ВХОДЯЩИХ соединений принято.
  ///
  /// Приложение показывает это в настройках. Без такой сводки «0 роздано»
  /// неотличимо от «раздаю, но никто не качает».
  Reachability get reachability;

  /// Подписаться на изменения [reachability] (маппинг получен/потерян/продлён,
  /// принято первое входящее соединение).
  bool onReachability(void Function(Reachability status) handler);

  bool offReachability(void Function(Reachability status) handler);

  int get allPeersNumber;

  int get connectedPeersNumber;

  int get seederNumber;

  /// Current download speed
  double get currentDownloadSpeed;

  /// Current upload speed
  double get uploadSpeed;

  /// Average download speed
  double get averageDownloadSpeed;

  /// Average upload speed
  double get averageUploadSpeed;

  // TODO debug:
  double get utpDownloadSpeed;
  // TODO debug:
  double get utpUploadSpeed;
  // TODO debug:
  int get utpPeerCount;

  /// Downloaded total bytes length
  int? get downloaded;

  /// Uploaded total bytes length (раздано — персистится в .bt.state)
  int? get uploaded;

  /// Downloaded percent
  double get progress;

  /// Сколько кусков забраковала рантайм-проверка SHA1 за жизнь задачи.
  ///
  /// Каждая единица — кусок, который собрался целиком, но не сошёлся с хэшем из
  /// metainfo: он не попал в bitfield и был перекачан заново. Устойчиво
  /// растущий счётчик означает, что в рое есть источник с испорченной копией.
  int get corruptedPiecesCount;

  /// Пиры, отключённые за битые куски (`адрес:порт`), — к ним задача больше не
  /// подключается.
  Set<String> get bannedPeerIds;

  /// Пути файлов торрента (относительные, как в metainfo), которые целиком
  /// лежат на диске: КАЖДЫЙ кусок, покрывающий байты файла, подтверждён
  /// локальным bitfield'ом.
  ///
  /// Считается по bitfield, а не по событиям [onFileComplete], и потому не
  /// зависит ни от того, докачали файл в этом запуске или он поднялся из
  /// recheck'а, ни от того, кому [DownloadFileManager] приписал кусок на стыке
  /// файлов. Приложению это нужно, чтобы открывать на воспроизведение ровно те
  /// файлы, которые дочитаны до последнего байта.
  ///
  /// Пустое множество, пока задача не инициализирована ([start]/[recheck]).
  Set<String> get completedFiles;

  /// Force re-verify the files already present on disk against the torrent's
  /// piece hashes, rebuilding (and persisting) the local bitfield.
  ///
  /// This is the standard BitTorrent "force re-check". It is meant to be called
  /// **before** [start]: a fresh task pointed at a folder of previously
  /// downloaded files (with no `.bt.state` file) would otherwise assume nothing
  /// is downloaded and re-fetch everything. After [recheck], fully present and
  /// hash-correct torrents come up complete/seeding, and partial ones resume
  /// from the right place.
  ///
  /// Each piece is read from disk in bounded chunks, SHA1-hashed and compared to
  /// `metainfo.pieces[i]`; matches set the bit in the [StateFile], missing or
  /// corrupt pieces stay unset. Returns the number of verified (complete)
  /// pieces.
  Future<int> recheck();

  /// Start to download
  Future start();

  /// Stop this task
  Future stop([bool force = false]);

  bool get isPaused;

  /// Pause task
  void pause();

  /// Resume task
  void resume();

  /// Delete downloaded files
  Future<void> delete();

  void requestPeersFromDHT();

  bool onTaskComplete(void Function() handler);

  bool offTaskComplete(void Function() handler);

  bool onFileComplete(void Function(String filepath) handler);

  bool offFileComplete(void Function(String filepath) handler);

  bool onStop(void Function() handler);

  bool offStop(void Function() handler);

  bool onPause(void Function() handler);

  bool offPause(void Function() handler);

  bool onResume(void Function() handler);

  bool offResume(void Function() handler);

  /// 增加DHT node，一般是将torrent文件中的nodes加入进去。
  ///
  /// 当然也可以直接添加已知的node地址
  void addDHTNode(Uri uri);

  /// 添加已知的Peer地址
  void addPeer(CompactAddress address,
      [PeerType type = PeerType.TCP, Socket socket]);
}

class _TorrentTask implements TorrentTask, AnnounceOptionsProvider {
  static InternetAddress LOCAL_ADDRESS =
      InternetAddress.fromRawAddress(Uint8List.fromList([127, 0, 0, 1]));

  final Set<void Function()> _taskCompleteHandlers = {};

  final Set<void Function(String filePath)> _fileCompleteHandlers = {};

  final Set<void Function()> _stopHandlers = {};

  final Set<void Function()> _resumeHandlers = {};

  final Set<void Function()> _pauseHandlers = {};

  final Set<void Function(Reachability status)> _reachabilityHandlers = {};

  TorrentAnnounceTracker? _tracker;

  DHT? _dht;

  LSD? _lsd;

  StateFile? _stateFile;

  PieceManager? _pieceManager;

  IsolatePieceVerifier? _pieceVerifier;

  DownloadFileManager? _fileManager;

  PeersManager? _peersManager;

  final Torrent? _metaInfo;

  final String _savePath;

  final Set<String> _peerIds = {};

  String? _peerId; // 这个是生成的本地peer的id，和Peer类的id是两回事

  ServerSocket? _serverSocket;

  ServerUTPSocket? _utpServer;

  bool _paused = false;

  /// Порт, который у нас попросили. Фактический может отличаться — см.
  /// [_bindListener].
  final int _configuredPort;

  final bool _enableUtp;

  final bool _enablePortMapping;

  PortMapper? _portMapper;

  StreamSubscription<PortMapperStatus>? _portMapperSub;

  PortMapperStatus _mappingStatus = const PortMapperStatus();

  int _incomingTcpCount = 0;
  int _incomingUtpCount = 0;
  int _incomingWanCount = 0;

  /// Последовательный режим выбора кусков и желаемый порядок кусков в нём
  /// (см. [TorrentTask.newTask]).
  final bool _sequential;

  final List<int>? _pieceOrder;

  _TorrentTask(
    this._metaInfo,
    this._savePath, {
    int listenPort = kDefaultListenPort,
    bool enableUtp = true,
    bool enablePortMapping = true,
    PortMapper? portMapper,
    bool sequential = false,
    List<int>? pieceOrder,
  })  : _configuredPort = listenPort,
        _enableUtp = enableUtp,
        _enablePortMapping = enablePortMapping,
        _portMapper = portMapper,
        _sequential = sequential,
        _pieceOrder = pieceOrder {
    _peerId = generatePeerId();
  }

  @override
  double get averageDownloadSpeed {
    if (_peersManager != null) {
      return _peersManager!.averageDownloadSpeed;
    } else {
      return 0.0;
    }
  }

  @override
  double get averageUploadSpeed {
    if (_peersManager != null) {
      return _peersManager!.averageUploadSpeed;
    } else {
      return 0.0;
    }
  }

  @override
  double get currentDownloadSpeed {
    if (_peersManager != null) {
      return _peersManager!.currentDownloadSpeed;
    } else {
      return 0.0;
    }
  }

  @override
  double get uploadSpeed {
    if (_peersManager != null) {
      return _peersManager!.uploadSpeed;
    } else {
      return 0.0;
    }
  }

  String? _infoHashString;

  Timer? _dhtRepeatTimer;

  Future<PeersManager> _init(Torrent model, String savePath) async {
    _dht = DHT();
    _lsd = LSD(model.infoHash, _peerId);
    _infoHashString = String.fromCharCodes(model.infoHashBuffer as Iterable<int>);
    _tracker ??= TorrentAnnounceTracker(this);
    _stateFile ??= await StateFile.getStateFile(savePath, model);
    // Хэш каждого докачанного куска считается в отдельном изоляте: у книги на
    // 3 ГБ кусков тысячи, а SHA1 в главном изоляте дёргал бы UI приложения.
    _pieceVerifier ??= await IsolatePieceVerifier.spawn(model, savePath);
    _pieceManager ??= PieceManager.createPieceManager(
        createPieceSelector(sequential: _sequential, pieceOrder: _pieceOrder),
        model,
        _stateFile!.bitfield,
        verifier: _pieceVerifier);
    _fileManager ??= await DownloadFileManager.createFileManager(
        model, savePath, _stateFile!);
    _peersManager ??= PeersManager(_peerId!, _pieceManager!, _pieceManager!,
        _fileManager!, model, MAX_WRITE_BUFFER_SIZE, _serverSocket?.port ?? 0);
    return _peersManager!;
  }

  @override
  void addPeer(CompactAddress address,
      [PeerType type = PeerType.TCP, Socket? socket]) {
    _peersManager?.addNewPeerAddress(address, type, socket);
  }

  void _whenTaskDownloadComplete() async {
    await _peersManager?.disposeAllSeeder('Download complete,disconnect seeder');
    await _tracker?.complete();
    // `Tracker.complete()` делает `stopIntervalAnnounce()` + `close()`: после
    // единственного `completed`-анонса периодический цикл мёртв, и трекер
    // выкидывает нас из сварма по истечении своего peer-таймаута. Для только
    // что докачавшего клиента это ровно тот же итог, что и блокер выше —
    // раздавать некому. Поднимаем цикл обратно.
    // Покрыто: test/seeding_announce_test.dart.
    _restartTrackerAnnounces();
    _fireTaskComplete();
  }

  /// Возобновить периодический анонс по всем announce-url торрента.
  ///
  /// Каждый url — отдельно и под защитой: `Tracker.restart()` БРОСАЕТ на уже
  /// выброшенном трекере, а выброшен он к этому моменту запросто —
  /// `Tracker.complete()` сам делает `dispose(e)`, если не достучался до
  /// трекера. Вызывают нас из `void ... async`-обработчика, поэтому исключение
  /// отсюда становится unhandled и роняет процесс целиком: на живом стенде
  /// качающий с недоступным трекером умирал ровно в момент завершения загрузки,
  /// не дописав файлы на диск.
  ///
  /// Недоступный трекер — не причина падать: раздача живёт и на LSD/DHT/PEX и
  /// на уже известных пирах.
  /// Покрыто: test/download_then_seed_test.dart.
  void _restartTrackerAnnounces() {
    final tracker = _tracker;
    if (tracker == null) return;
    for (var url in _metaInfo!.announces) {
      try {
        tracker.restartTracker(url);
      } catch (e) {
        log('не удалось возобновить анонсы на $url: $e',
            name: runtimeType.toString());
      }
    }
  }

  void _whenFileDownloadComplete(String filePath) {
    _fireFileComplete(filePath);
  }

  void _processTrackerPeerEvent(Tracker source, PeerEvent event) {
    var ps = event.peers;
    if (ps.isNotEmpty) {
      for (var url in ps) {
        _processNewPeerFound(url);
      }
    }
  }

  /// Пир, найденный через Local Service Discovery (BEP 14).
  ///
  /// Раньше здесь стоял только отладочный `print` — найденный в локальной сети
  /// пир выбрасывался, и раздача между двумя устройствами в одном Wi-Fi не
  /// работала вовсе, даже когда трекер недоступен.
  ///
  /// Мультикаст-сокет LSD принимает анонсы ВСЕХ торрентов в сети, поэтому
  /// infohash обязателен к сверке — иначе в сварм чужой книги полетели бы наши
  /// подключения. Сравнение регистронезависимое: BEP 14 не фиксирует регистр
  /// hex, и клиенты шлют по-разному.
  /// Покрыто: test/lsd_peer_test.dart.
  void _processLSDPeerEvent(CompactAddress address, String infoHash) {
    final mine = _metaInfo?.infoHash;
    if (mine == null) return;
    if (infoHash.toLowerCase() != mine.toLowerCase()) return;
    _processNewPeerFound(address);
  }

  void _processNewPeerFound(CompactAddress url) {
    _peersManager?.addNewPeerAddress(url);
  }

  void _processDHTPeer(CompactAddress peer, String infoHash) {
    if (infoHash == _infoHashString) {
      _processNewPeerFound(peer);
    }
  }

  void _hookInPeer(Socket socket) {
    if (socket.remoteAddress == LOCAL_ADDRESS) {
      socket.close();
      return;
    }
    log('incoming connect: ${socket.remoteAddress.address}:${socket.remotePort}',
        name: runtimeType.toString());
    // `socket.address`/`socket.port` — это НАША сторона (bind-адрес 0.0.0.0 и
    // наш же слушающий порт), а не подключившийся пир. Из-за подмены каждый
    // входящий регистрировался под одним и тем же фиктивным адресом, а старый
    // счётчик `_cominIp` на `socket.address` навсегда занимался первым же
    // подключением и не освобождался — второе входящее соединение за всю жизнь
    // задачи закрывалось сразу. Для раздачи это означало ровно одного
    // качающего, и то до первого обрыва.
    //
    // Лимит входящих переехал в PeersManager: там адрес освобождается, когда
    // пир отваливается.
    // Покрыто: test/incoming_peers_test.dart.
    _countIncoming(socket.remoteAddress, PeerType.TCP);
    _peersManager?.addNewPeerAddress(
        CompactAddress(socket.remoteAddress, socket.remotePort),
        PeerType.TCP,
        socket);
  }

  /// Входящее uTP-соединение.
  ///
  /// Раньше и `ServerUTPSocket.bind`, и этот обработчик были закомментированы:
  /// исходящий uTP работал, входящий — нет. Для пользователя за NAT это
  /// половина шансов: у части роутеров UDP проходит там, где TCP-соединение
  /// не устанавливается.
  ///
  /// Дальше входящий uTP-пир ничем не отличается от входящего TCP: `UTPSocket`
  /// реализует `Socket`, а [PeersManager.addNewPeerAddress] с готовым сокетом
  /// сам заводит пира как принятого (`incoming: true`).
  /// Покрыто: test/incoming_utp_test.dart.
  void _hookUTP(UTPSocket socket) {
    // Тот же запрет на соединение с самим собой, что и в [_hookInPeer].
    if (socket.remoteAddress == LOCAL_ADDRESS) {
      socket.close();
      return;
    }
    log('incoming uTP connect: '
        '${socket.remoteAddress.address}:${socket.remotePort}',
        name: runtimeType.toString());
    _countIncoming(socket.remoteAddress, PeerType.UTP);
    _peersManager?.addNewPeerAddress(
        CompactAddress(socket.remoteAddress, socket.remotePort),
        PeerType.UTP,
        socket);
  }

  /// Учёт входящих для диагностики достижимости.
  ///
  /// Соединения из локальной сети считаются отдельно: сосед по Wi-Fi, нашедший
  /// нас через LSD, ничего не доказывает о проходимости NAT, а входящее с
  /// публичного адреса — доказывает.
  void _countIncoming(InternetAddress remote, PeerType type) {
    if (type == PeerType.UTP) {
      _incomingUtpCount++;
    } else {
      _incomingTcpCount++;
    }
    if (!isPrivateAddress(remote)) _incomingWanCount++;
    _fireReachabilityChanged();
  }

  @override
  void pause() {
    if (_paused) return;
    _paused = true;
    _peersManager?.pause();
    _fireTaskPaused();
  }

  @override
  bool get isPaused => _paused;

  @override
  void resume() {
    if (isPaused) {
      _paused = false;
      _peersManager?.resume();
      _fireTaskResume();
    }
  }

  @override
  Future<int> recheck() async {
    final model = _metaInfo!;
    // Ensure a StateFile exists so verified pieces are persisted across runs.
    // This is safe to do before start(); start() reuses the same instance via
    // its `??=` guards.
    _stateFile ??= await StateFile.getStateFile(_savePath, model);
    final stateFile = _stateFile!;

    final result = await verifyExistingFiles(model, _savePath);

    // Reconcile the persisted bitfield with what we just verified on disk:
    // set bits for pieces that now hash-check, clear ones that no longer do.
    for (var i = 0; i < result.totalPieces; i++) {
      final have = result.bitfield.getBit(i);
      if (stateFile.bitfield.getBit(i) != have) {
        await stateFile.updateBitfield(i, have);
      }
    }
    return result.verifiedPieces;
  }

  /// Занять слушающий TCP-порт.
  ///
  /// Занятый порт — не повод падать: клиент с эфемерным портом всё ещё качает
  /// и раздаёт исходящими соединениями, просто снаружи его не найти. Об этом
  /// честно сообщает [reachability] (`listeningOnConfiguredPort == false`).
  /// Покрыто: test/listen_port_test.dart.
  Future<ServerSocket> _bindListener() async {
    if (_configuredPort != kEphemeralListenPort) {
      try {
        return await ServerSocket.bind(InternetAddress.anyIPv4, _configuredPort);
      } on SocketException catch (e) {
        log(
            'слушающий порт $_configuredPort занят ($e) — берём эфемерный. '
            'Ручной проброс на $_configuredPort работать не будет',
            name: runtimeType.toString());
      }
    }
    return await ServerSocket.bind(
        InternetAddress.anyIPv4, kEphemeralListenPort);
  }

  /// Занять UDP-порт под входящий uTP.
  ///
  /// Номер тот же, что у TCP, — так делают все клиенты, и так один проброс на
  /// роутере закрывает оба транспорта. DHT в этом стеке слушает собственный
  /// фиксированный UDP 6881 (см. `dht_dart`), поэтому конфликта с ним нет,
  /// пока слушающий порт не выставлен в 6881 вручную.
  ///
  /// `reuseAddress: false` здесь обязателен. UDP-сокет с `SO_REUSEADDR`
  /// (умолчание Dart) встаёт на УЖЕ занятый чужим процессом адрес без всякой
  /// ошибки, после чего входящие датаграммы достаются только одному из двух
  /// сокетов: слушатель выглядел бы совершенно здоровым, не принимая при этом
  /// ничего. С выключенным reuse конфликт честно приходит исключением, и мы
  /// откатываемся на эфемерный порт — без проброса, но рабочий.
  /// Покрыто: test/listen_port_test.dart.
  Future<ServerUTPSocket?> _bindUtp(int port) async {
    try {
      return await ServerUTPSocket.bind(InternetAddress.anyIPv4, port, false);
    } catch (e) {
      log('UDP $port под uTP занят ($e) — пробуем эфемерный',
          name: runtimeType.toString());
    }
    try {
      return await ServerUTPSocket.bind(
          InternetAddress.anyIPv4, kEphemeralListenPort, false);
    } catch (e) {
      // uTP — не единственный транспорт: без него остаётся TCP.
      log('не удалось поднять приём uTP: $e', name: runtimeType.toString());
      return null;
    }
  }

  @override
  Future start() async {
    // 进入的peer：
    _serverSocket ??= await _bindListener();
    await _init(_metaInfo!, _savePath);
    _serverSocket?.listen(_hookInPeer);
    if (_enableUtp) {
      _utpServer ??= await _bindUtp(_serverSocket!.port);
      _utpServer?.listen(_hookUTP);
    }
    // ignore: unawaited_futures
    _startPortMapping();

    var map = {};
    map['name'] = _metaInfo!.name;
    map['tcp_socket'] = _serverSocket!.port;
    map['utp_socket'] = _utpServer?.port ?? 0;
    map['comoplete_pieces'] = List.from(_stateFile!.bitfield.completedPieces);
    map['total_pieces_num'] = _stateFile!.bitfield.piecesNum;
    map['downloaded'] = _stateFile!.downloaded;
    map['uploaded'] = _stateFile!.uploaded;
    map['total_length'] = _metaInfo!.length;
    // 主动访问的peer:
    _tracker?.onPeerEvent(_processTrackerPeerEvent);
    _peersManager?.onAllComplete(_whenTaskDownloadComplete);
    _fileManager?.onFileComplete(_whenFileDownloadComplete);

    _lsd?.onLSDPeer(_processLSDPeerEvent);
    _lsd?.port = _serverSocket!.port;
    _lsd?.start();

    _dht?.announce(
        String.fromCharCodes(_metaInfo!.infoHashBuffer!), _announcePort!);
    _dht?.onNewPeer(_processDHTPeer);
    // ignore: unawaited_futures
    _dht?.bootstrap();
    // Анонс `started` шлём ВСЕГДА, в том числе для уже полного торрента.
    //
    // Раньше полный торрент уходил в ветку `_tracker.complete()`, а
    // `TorrentAnnounceTracker.complete()` перебирает карту `_trackers`, которую
    // заполняет только `runTracker()`/`runTrackers()`. На старте карта пуста →
    // ни одного обращения к трекеру → чистого сида никто не находил (это и есть
    // «0 роздано» после перезапуска приложения с уже скачанными книгами).
    //
    // Ветка была неверна и по протоколу: BEP 3 требует НЕ слать `completed`,
    // если торрент был полон уже на старте клиента. Сид анонсируется как все,
    // просто с `left=0` (см. [getOptions]).
    // Покрыто: test/seeding_announce_test.dart.
    _tracker?.runTrackers(_metaInfo!.announces, _metaInfo!.infoHashBuffer!,
        event: EVENT_STARTED);
    return map;
  }

  /// Пробить слушающий порт на роутере.
  ///
  /// Запускается «в фоне» намеренно: discovery UPnP — это мультикаст с
  /// ожиданием ответов, и держать на нём `start()` (а с ним и UI приложения)
  /// нельзя. До того как маппинг получен, задача уже работает — просто пока
  /// без внешнего порта.
  Future<void> _startPortMapping() async {
    if (!_enablePortMapping) return;
    final port = _serverSocket?.port;
    if (port == null) return;
    final mapper = _portMapper ??= PortMapper();
    _portMapperSub ??= mapper.onStatus.listen((status) {
      _mappingStatus = status;
      _fireReachabilityChanged();
    });
    try {
      // Оба протокола: TCP — обычные пиры, UDP — входящий uTP.
      await mapper.map(internalPort: port);
    } catch (e) {
      log('проброс порта не удался: $e', name: runtimeType.toString());
    }
  }

  /// Порт, который мы сообщаем сварму, — ЕДИНСТВЕННЫЙ источник для трекера и
  /// DHT.
  ///
  /// Это внешний порт, если он получен: на живом роутере запрос внутреннего
  /// 51413 вернул внешний 51414, и анонс локального номера отправил бы весь
  /// сварм стучаться в закрытую дверь. Маппинг приходит асинхронно, поэтому
  /// читается состояние на момент анонса, а не снимок со старта.
  ///
  /// LSD сюда НЕ ходит намеренно: он живёт в пределах широковещательного
  /// домена, и внешний порт соседу по Wi-Fi бесполезен.
  ///
  /// Один геттер на обоих потребителей — чтобы «трекер и DHT анонсируют одно и
  /// то же» держалось кодом, а не внимательностью.
  /// Покрыто (через трекер): test/announce_external_port_test.dart.
  int? get _announcePort =>
      _mappingStatus.externalTcpPort ?? _serverSocket?.port;

  @override
  Reachability get reachability {
    final status = _mappingStatus;
    return Reachability(
      configuredPort: _configuredPort,
      listenPort: _serverSocket?.port ?? 0,
      utpPort: _utpServer?.port ?? 0,
      mappingMethod: status.method,
      externalAddress: status.externalAddress,
      externalTcpPort: status.externalTcpPort,
      externalUdpPort: status.externalUdpPort,
      mappingExpiresAt: status.expiresAt,
      mappingError: status.error,
      incomingTcpConnections: _incomingTcpCount,
      incomingUtpConnections: _incomingUtpCount,
      incomingFromWanConnections: _incomingWanCount,
    );
  }

  @override
  bool onReachability(void Function(Reachability status) handler) =>
      _reachabilityHandlers.add(handler);

  @override
  bool offReachability(void Function(Reachability status) handler) =>
      _reachabilityHandlers.remove(handler);

  void _fireReachabilityChanged() {
    if (_reachabilityHandlers.isEmpty) return;
    final snapshot = reachability;
    for (var handler in _reachabilityHandlers) {
      Timer.run(() => handler(snapshot));
    }
  }

  @override
  Future stop([bool force = false]) async {
    await _tracker?.stop(force);
    var tempHandler = Set<Function>.from(_stopHandlers);
    await dispose();
    for (var element in tempHandler) {
      Timer.run(() => element());
    }
    tempHandler.clear();
    //tempHandler = null;
  }

  Future dispose() async {
    _dhtRepeatTimer?.cancel();
    _dhtRepeatTimer = null;
    _fileCompleteHandlers.clear();
    _taskCompleteHandlers.clear();
    _pauseHandlers.clear();
    _resumeHandlers.clear();
    _stopHandlers.clear();
    _reachabilityHandlers.clear();
    // Маппинг снимаем ДО закрытия сокетов: аренда на роутере живёт своим
    // сроком и, если её не снять, порт останется висеть проброшенным на
    // машину, которая его больше не слушает.
    await _portMapperSub?.cancel();
    _portMapperSub = null;
    await _portMapper?.dispose();
    _portMapper = null;
    _mappingStatus = const PortMapperStatus();
    _tracker?.offPeerEvent(_processTrackerPeerEvent);
    _peersManager?.offAllComplete(_whenTaskDownloadComplete);
    _fileManager?.offFileComplete(_whenFileDownloadComplete);
    // 这是有顺序的,先停止tracker运行,然后停止监听serversocket以及所有的peer,最后关闭文件系统
    await _tracker?.dispose();
    _tracker = null;
    await _peersManager?.dispose();
    _peersManager = null;
    await _serverSocket?.close();
    _serverSocket = null;
    await _utpServer?.close();
    _utpServer = null;
    await _fileManager?.close();
    _fileManager = null;
    // Изолят-хэшер держит собственные read-хэндлы на файлы книги — гасим его
    // после файлового менеджера, чтобы не оставить их висеть.
    await _pieceVerifier?.dispose();
    _pieceVerifier = null;
    await _dht?.stop();
    _dht = null;

    _lsd?.close();
    _lsd = null;
    _peerIds.clear();
    return;
  }

  @override
  Future<Map<String, dynamic>> getOptions(Uri uri, String infoHash) {
    var map = {
      'downloaded': _stateFile?.downloaded,
      'uploaded': _stateFile?.uploaded,
      'left': _metaInfo!.length! - _stateFile!.downloaded,
      'numwant': 50,
      'compact': 1,
      'peerId': _peerId,
      'port': _announcePort
    };
    return Future.value(map);
  }

  @override
  bool offFileComplete(void Function(String filepath) handler) {
    return _fileCompleteHandlers.remove(handler);
  }

  void _fireFileComplete(String filepath) {
    for (var handler in _fileCompleteHandlers) {
      Timer.run(() => handler(filepath));
    }
  }

  @override
  bool offPause(void Function() handler) {
    return _pauseHandlers.remove(handler);
  }

  @override
  bool offResume(void Function() handler) {
    return _resumeHandlers.remove(handler);
  }

  @override
  bool offStop(void Function() handler) {
    return _stopHandlers.remove(handler);
  }

  @override
  bool offTaskComplete(void Function() handler) {
    return _taskCompleteHandlers.remove(handler);
  }

  @override
  bool onFileComplete(void Function(String filepath) handler) {
    return _fileCompleteHandlers.add(handler);
  }

  @override
  bool onPause(void Function() handler) {
    return _pauseHandlers.add(handler);
  }

  @override
  bool onResume(void Function() handler) {
    return _resumeHandlers.add(handler);
  }

  @override
  bool onStop(void Function() handler) {
    return _stopHandlers.add(handler);
  }

  @override
  bool onTaskComplete(void Function() handler) {
    return _taskCompleteHandlers.add(handler);
  }

  void _fireTaskComplete() {
    for (var element in _taskCompleteHandlers) {
      Timer.run(() => element());
    }
  }

  @override
  int? get downloaded => _fileManager?.downloaded;

  @override
  int? get uploaded => _fileManager?.uploaded;



  @override
  double get progress {
    var d = downloaded;
    if (d == null) return 0.0;
    var l = _metaInfo?.length;
    if (l == null) return 0.0;
    return d / l;
  }

  @override
  int get corruptedPiecesCount => _peersManager?.corruptedPiecesCount ?? 0;

  @override
  Set<String> get bannedPeerIds => _peersManager?.bannedPeerIds ?? const {};

  @override
  Set<String> get completedFiles {
    var model = _metaInfo;
    var stateFile = _stateFile;
    if (model == null || stateFile == null) return const {};
    return completedFilesOf(model, stateFile.bitfield.getBit);
  }

  void _fireTaskPaused() {
    for (var element in _pauseHandlers) {
      Timer.run(() => element());
    }
  }

  void _fireTaskResume() {
    for (var element in _resumeHandlers) {
      Timer.run(() => element());
    }
  }

  @override
  int get allPeersNumber {
    if (_peersManager != null) {
      return _peersManager!.peersNumber;
    } else {
      return 0;
    }
  }

  @override
  void addDHTNode(Uri url) {
    _dht?.addBootstrapNode(url);
  }

  @override
  int get connectedPeersNumber {
    if (_peersManager != null) {
      return _peersManager!.connectedPeersNumber;
    } else {
      return 0;
    }
  }

  @override
  int get seederNumber {
    if (_peersManager != null) {
      return _peersManager!.seederNumber;
    } else {
      return 0;
    }
  }

  // TODO debug:
  @override
  double get utpDownloadSpeed {
    if (_peersManager == null) return 0.0;
    return _peersManager!.utpDownloadSpeed;
  }

// TODO debug:
  @override
  double get utpUploadSpeed {
    if (_peersManager == null) return 0.0;
    return _peersManager!.utpUploadSpeed;
  }

// TODO debug:
  @override
  int get utpPeerCount {
    if (_peersManager == null) return 0;
    return _peersManager!.utpPeerCount;
  }

  @override
  void startAnnounceUrl(Uri url, Uint8List infoHash) {
    _tracker?.runTracker(url, infoHash);
  }

  @override
  void requestPeersFromDHT() {
    if (_metaInfo == null) return;
    _dht?.requestPeers(String.fromCharCodes(_metaInfo!.infoHashBuffer as Iterable<int>));
  }

  @override
  Future<void> delete() async {
    log('deleting torrent file fileManager= $_fileManager', name: runtimeType.toString());
    await _fileManager?.delete();
    return;
  }
}
