import 'dart:io';

import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Слушающий порт задачи.
///
/// До этой волны порт был эфемерным (`ServerSocket.bind(anyIPv4, 0)`) и менялся
/// при каждом запуске: ни ручной проброс на роутере, ни устойчивый автоматический
/// маппинг были невозможны в принципе — клиент был недостижим извне by design.
void main() {
  late Directory tmp;
  late dynamic model;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('listenport_');
    final files = [MapEntry('book.mp3', pseudoBytes(20 * 1024, 5))];
    model = buildTorrent(
      name: 'port-book',
      pieceLength: 16 * 1024,
      files: files,
      infoHashSeed: 77,
    );
    await writeFiles(tmp, model, files);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('задача слушает именно тот порт, который у неё попросили', () async {
    final port = await _freePort();
    final task = TorrentTask.newTask(model, tmp.path,
        listenPort: port, enableUtp: false, enablePortMapping: false);

    final map = await task.start();
    try {
      expect(map['tcp_socket'], equals(port));
      expect(task.reachability.listenPort, equals(port));
      expect(task.reachability.configuredPort, equals(port));
      expect(task.reachability.listeningOnConfiguredPort, isTrue);
    } finally {
      await task.stop();
    }
  });

  test('занятый порт — откат на эфемерный, а не падение', () async {
    final port = await _freePort();
    // ПРЕДУСЛОВИЕ: порт действительно занят. Без этой проверки тест прошёл бы
    // по пустому пути — «откатились на эфемерный» подтверждалось бы на порту,
    // который никто не занимал.
    final squatter = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await expectLater(
      ServerSocket.bind(InternetAddress.anyIPv4, port),
      throwsA(isA<SocketException>()),
      reason: 'предусловие: второй bind на этот порт обязан падать, '
          'иначе проверять нечего',
    );

    final task = TorrentTask.newTask(model, tmp.path,
        listenPort: port, enableUtp: false, enablePortMapping: false);

    try {
      final map = await task.start();
      final actual = map['tcp_socket'] as int;
      expect(actual, isNot(equals(port)),
          reason: 'порт занят — обязаны взять другой');
      expect(actual, isNot(equals(0)),
          reason: 'эфемерный bind выдаёт настоящий номер порта');
      expect(task.reachability.listeningOnConfiguredPort, isFalse,
          reason: 'пользователь, пробросивший $port руками, должен узнать, '
              'что проброс сейчас ведёт в никуда');
      expect(task.reachability.configuredPort, equals(port),
          reason: 'просили-то именно $port — это и показываем в диагностике');
    } finally {
      await task.stop();
      await squatter.close();
    }
  });

  test('kEphemeralListenPort сохраняет старое поведение — любой свободный порт',
      () async {
    final task = TorrentTask.newTask(model, tmp.path,
        listenPort: kEphemeralListenPort,
        enableUtp: false,
        enablePortMapping: false);

    final map = await task.start();
    try {
      expect(map['tcp_socket'], greaterThan(0));
      expect(task.reachability.configuredPort, equals(kEphemeralListenPort));
    } finally {
      await task.stop();
    }
  });

  test('uTP слушает UDP на том же номере порта, что и TCP', () async {
    final port = await _freePort();
    final task = TorrentTask.newTask(model, tmp.path,
        listenPort: port, enableUtp: true, enablePortMapping: false);

    final map = await task.start();
    try {
      expect(map['tcp_socket'], equals(port),
          reason: 'предусловие: TCP занял именно запрошенный порт');
      expect(map['utp_socket'], equals(port),
          reason: 'один номер на оба транспорта — тогда один проброс на '
              'роутере закрывает и TCP-пиров, и uTP');
      expect(task.reachability.utpPort, equals(port));
    } finally {
      await task.stop();
    }
  });

  test('без enableUtp UDP-сокет не поднимается', () async {
    final port = await _freePort();
    final task = TorrentTask.newTask(model, tmp.path,
        listenPort: port, enableUtp: false, enablePortMapping: false);

    final map = await task.start();
    try {
      expect(map['utp_socket'], equals(0));
      expect(task.reachability.utpPort, equals(0));
    } finally {
      await task.stop();
    }
  });

  test('UDP того же номера занят — uTP откатывается на эфемерный, TCP цел',
      () async {
    final port = await _freePort();
    // ПРЕДУСЛОВИЕ: UDP-порт занят кем-то посторонним (в реальности это будет
    // DHT на 6881 или второй экземпляр приложения).
    //
    // Занимаем БЕЗ reuseAddress и проверяем, что повторный bind без reuse
    // действительно падает. С reuseAddress (умолчание Dart) он не падает
    // вовсе — именно поэтому [_bindUtp] отключает reuse: иначе конфликта не
    // возникло бы, а датаграммы молча уходили бы чужому сокету.
    final squatter = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port,
        reuseAddress: false);
    await expectLater(
      RawDatagramSocket.bind(InternetAddress.anyIPv4, port,
          reuseAddress: false),
      throwsA(isA<SocketException>()),
      reason: 'предусловие: второй bind на этот UDP-порт обязан падать',
    );

    final task = TorrentTask.newTask(model, tmp.path,
        listenPort: port, enableUtp: true, enablePortMapping: false);

    try {
      final map = await task.start();
      expect(map['tcp_socket'], equals(port),
          reason: 'занятый UDP не должен утаскивать за собой TCP');
      final utpPort = map['utp_socket'] as int;
      expect(utpPort, greaterThan(0),
          reason: 'приём uTP должен подняться хотя бы на эфемерном порту');
      expect(utpPort, isNot(equals(port)));
    } finally {
      await task.stop();
      squatter.close();
    }
  });

  test('маппинг выключен — диагностика честно говорит "способа нет"', () async {
    final port = await _freePort();
    final task = TorrentTask.newTask(model, tmp.path,
        listenPort: port, enableUtp: false, enablePortMapping: false);

    await task.start();
    try {
      final r = task.reachability;
      expect(r.mappingMethod, equals(PortMapMethod.none));
      expect(r.externalEndpoint, isNull);
      expect(r.provenReachable, isFalse,
          reason: 'входящих ещё не было — достижимость не доказана');
    } finally {
      await task.stop();
    }
  });
}

/// Свободный порт: занимаем и сразу отпускаем.
///
/// Гонка тут возможна, но окно микроскопическое, а альтернатива (фиксированный
/// номер) ломала бы параллельный прогон тестов гарантированно.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}
