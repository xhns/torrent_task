import 'dart:io';

import 'package:test/test.dart';
import 'package:torrent_task/torrent_task.dart';

import 'seeding_support.dart';

/// Какой порт уходит в анонс, когда порт проброшен на роутере.
///
/// Внешний порт не обязан совпадать с внутренним: на живом роутере запрос
/// внутреннего 51413 вернул внешний 51414 (51413 на шлюзе был занят). Анонс
/// локального номера в такой ситуации отправляет весь сварм стучаться в
/// закрытую дверь — раздача выглядит живой и не отдаёт ничего.
///
/// Проброс здесь подставной: настоящий роутер тестам недоступен, да и не нужен
/// — проверяется выбор номера, а не работа UPnP.
void main() {
  late Directory tmp;
  late StubTracker tracker;
  late TorrentTask task;
  late int listenPort;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('announce_ext_');
    // Частый анонс: маппинг приходит асинхронно, и первый (`started`) анонс
    // вполне может успеть уйти раньше него.
    tracker = await StubTracker.start(interval: 1);
    final files = [MapEntry('book.mp3', pseudoBytes(20 * 1024, 4))];
    // Уникальный по каталогу тестов seed — см. пояснение в incoming_utp_test.
    final model = buildTorrent(
      name: 'announce-book',
      pieceLength: 16 * 1024,
      files: files,
      announces: [tracker.announceUrl],
      infoHashSeed: 79,
    );
    await writeFiles(tmp, model, files);

    final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    listenPort = probe.port;
    await probe.close();

    task = TorrentTask.newTask(model, tmp.path,
        listenPort: listenPort,
        enableUtp: false,
        portMapper: PortMapper(backends: [_ShiftingBackend()]));
    await task.recheck();
  });

  tearDown(() async {
    await task.stop();
    await tracker.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('трекеру анонсируется ВНЕШНИЙ порт, а не локальный', () async {
    await task.start();

    // ПРЕДУСЛОВИЕ: маппинг действительно получен и внешний порт ОТЛИЧАЕТСЯ от
    // локального. Совпади они — тест был бы зелёным при любом поведении.
    await _waitFor(() => task.reachability.externalTcpPort != null);
    final external = task.reachability.externalTcpPort;
    expect(external, isNotNull, reason: 'предусловие: порт проброшен');
    expect(external, isNot(equals(listenPort)),
        reason: 'предусловие: внешний и локальный номера обязаны различаться, '
            'иначе проверять нечего');

    await _waitFor(() => tracker.hits.any((h) => h.port == external));

    expect(tracker.hits, isNotEmpty, reason: 'предусловие: анонсы вообще шли');
    expect(tracker.hits.map((h) => h.port), contains(external),
        reason: 'сварм должен идти на внешний порт: локальный номер за NAT '
            'ему недоступен');
  });

  test('пока маппинга нет, анонсируется локальный порт', () async {
    // До получения маппинга анонс всё равно должен уходить: клиент с закрытым
    // портом качает исходящими соединениями и обязан быть в сварме.
    await task.start();
    await _waitFor(() => tracker.hits.isNotEmpty);
    expect(tracker.hits, isNotEmpty);
    final firstPorts = tracker.hits.map((h) => h.port).toSet();
    expect(firstPorts.every((p) => p == listenPort || p == listenPort + 1),
        isTrue,
        reason: 'до маппинга — локальный порт, после — внешний; ничего '
            'третьего в анонсе быть не может, получили $firstPorts');
  });
}

/// Подставной проброс: внешний порт всегда на единицу больше внутреннего —
/// ровно так повёл себя настоящий роутер на стенде.
class _ShiftingBackend implements NatBackend {
  @override
  PortMapMethod get method => PortMapMethod.natPmp;

  @override
  String? lastError;

  @override
  Future<MappedPort?> map({
    required int internalPort,
    required PortProtocol protocol,
    required Duration lease,
    int? suggestedExternalPort,
  }) async {
    return MappedPort(
      method: method,
      protocol: protocol,
      internalPort: internalPort,
      externalPort: internalPort + 1,
      externalAddress: InternetAddress('109.195.195.251'),
      lifetime: lease,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<bool> unmap(MappedPort mapping) async => true;

  @override
  Future<InternetAddress?> externalAddress() async =>
      InternetAddress('109.195.195.251');

  @override
  Future<void> dispose() async {}
}

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future.delayed(const Duration(milliseconds: 20));
  }
}
