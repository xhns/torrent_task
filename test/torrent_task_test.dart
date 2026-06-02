import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bencode_dart/bencode_dart.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:test/test.dart';

import 'package:torrent_task/torrent_task.dart';
import 'package:torrent_task/src/metadata/metadata_messager.dart';
import 'package:torrent_task/src/piece/base_piece_selector.dart';

void main() {
  group('Bitfield', () {
    test('set / get / clear a single bit', () {
      final bf = Bitfield.createEmptyBitfield(20);
      expect(bf.getBit(5), isFalse);
      bf.setBit(5, true);
      expect(bf.getBit(5), isTrue);
      // neighbouring bits stay untouched
      expect(bf.getBit(4), isFalse);
      expect(bf.getBit(6), isFalse);
      bf.setBit(5, false);
      expect(bf.getBit(5), isFalse);
    });

    test('out-of-range indices are ignored, never throw', () {
      final bf = Bitfield.createEmptyBitfield(8);
      expect(bf.getBit(-1), isFalse);
      expect(bf.getBit(100), isFalse);
      // setting out of range is a no-op
      bf.setBit(-1, true);
      bf.setBit(100, true);
      expect(bf.haveCompletePiece(), isFalse);
    });

    test('completedPieces lists exactly the set bits, in order', () {
      final bf = Bitfield.createEmptyBitfield(32);
      for (final i in [0, 7, 8, 9, 31]) {
        bf.setBit(i, true);
      }
      expect(bf.completedPieces..sort(), equals([0, 7, 8, 9, 31]));
    });

    test('haveAll / haveNone', () {
      final bf = Bitfield.createEmptyBitfield(10);
      expect(bf.haveNone(), isTrue);
      expect(bf.haveAll(), isFalse);
      for (var i = 0; i < 10; i++) {
        bf.setBit(i, true);
      }
      expect(bf.haveAll(), isTrue);
      expect(bf.haveNone(), isFalse);
      // a bit beyond piecesNum must not be required for haveAll
      expect(bf.getBit(10), isFalse);
    });

    test('copyFrom round-trips the raw buffer', () {
      final src = Bitfield.createEmptyBitfield(16);
      src.setBit(3, true);
      src.setBit(12, true);
      final copy = Bitfield.copyFrom(16, src.buffer);
      expect(copy.getBit(3), isTrue);
      expect(copy.getBit(12), isTrue);
      expect(copy.buffer, equals(src.buffer));
    });
  });

  group('utils', () {
    test('generatePeerId uses prefix and is fixed length', () {
      final id = generatePeerId();
      expect(id.startsWith(ID_PREFIX), isTrue);
      // prefix (8) + base64 of 9 bytes (12) = 20, the BT peer-id length
      expect(id.length, equals(20));
    });

    test('hexString2Buffer parses lower/upper hex', () {
      expect(hexString2Buffer('00ff10AB'), equals([0x00, 0xff, 0x10, 0xab]));
    });

    test('hexString2Buffer rejects odd-length and empty input', () {
      expect(hexString2Buffer(''), isNull);
      expect(hexString2Buffer('abc'), isNull);
    });
  });

  group('BEP9 metadata messages (bencode round-trip)', () {
    test('request message decodes back to {msg_type:0, piece}', () {
      final bytes = createRequestMessage(7)!;
      final m = decode(bytes) as Map;
      expect(m['msg_type'], equals(0));
      expect(m['piece'], equals(7));
    });

    test('reject message decodes back to {msg_type:2, piece}', () {
      final bytes = createRejectMessage(3)!;
      final m = decode(bytes) as Map;
      expect(m['msg_type'], equals(2));
      expect(m['piece'], equals(3));
    });

    test('data message carries msg_type:1, piece and total_size', () {
      final block = List<int>.generate(1234, (i) => i % 256);
      final bytes = createDataMessage(2, block)!;
      final m = decode(bytes) as Map;
      expect(m['msg_type'], equals(1));
      expect(m['piece'], equals(2));
      expect(m['total_size'], equals(block.length));
    });
  });

  group('PEX (bencode round-trip)', () {
    test('added/dropped compact peers survive encode -> decode', () {
      final added = <CompactAddress>[
        CompactAddress(InternetAddress.tryParse('1.2.3.4')!, 6881),
        CompactAddress(InternetAddress.tryParse('10.0.0.1')!, 51413),
      ];
      final dropped = <CompactAddress>[
        CompactAddress(InternetAddress.tryParse('8.8.8.8')!, 1234),
      ];

      final data = <String, List<int>>{'added': [], 'dropped': []};
      for (final a in added) {
        data['added']!.addAll(a.toBytes());
      }
      for (final d in dropped) {
        data['dropped']!.addAll(d.toBytes());
      }

      final encoded = encode(data) as Uint8List;
      final decoded = decode(encoded) as Map;

      // bencode strings come back as byte lists; parse them as compact peers.
      final parsedAdded =
          CompactAddress.parseIPv4Addresses(_asBytes(decoded['added']));
      final parsedDropped =
          CompactAddress.parseIPv4Addresses(_asBytes(decoded['dropped']));

      expect(parsedAdded.map((e) => e.toString()),
          equals(added.map((e) => e.toString())));
      expect(parsedDropped.map((e) => e.toString()),
          equals(dropped.map((e) => e.toString())));
    });
  });

  group('BasePieceSelector', () {
    test('returns null when no piece is downloadable for the peer', () {
      final selector = BasePieceSelector();
      final provider = _FakePieceProvider({});
      expect(selector.selectPiece('peerA', [0, 1, 2], provider), isNull);
    });

    test('only considers pieces available to the requesting peer', () {
      final selector = BasePieceSelector();
      // piece 0 has no peers (unavailable), piece 1 is available.
      final p0 = _FakePiece(0, peers: 0, subPieces: 4);
      final p1 = _FakePiece(1, peers: 3, subPieces: 4);
      final provider = _FakePieceProvider({0: p0, 1: p1});
      final picked = selector.selectPiece('peerA', [0, 1], provider);
      expect(picked, same(p1));
    });

    test('always returns one of the available candidate pieces', () {
      final selector = BasePieceSelector();
      final p0 = _FakePiece(0, peers: 5, subPieces: 4);
      final p1 = _FakePiece(1, peers: 2, subPieces: 4);
      final p2 = _FakePiece(2, peers: 3, subPieces: 1);
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2});
      for (final random in [false, true]) {
        final picked =
            selector.selectPiece('peerA', [0, 1, 2], provider, random);
        expect([p0, p1, p2], contains(picked),
            reason: 'random=$random must pick a real candidate');
      }
    });

    test('rarest-first: picks the piece with the fewest available peers', () {
      final selector = BasePieceSelector();
      // p2 is the rarest (2 peers). It is neither first nor last in the list,
      // which is exactly the case the old "return first that beats current"
      // logic got wrong.
      final p0 = _FakePiece(0, peers: 9, subPieces: 4);
      final p1 = _FakePiece(1, peers: 5, subPieces: 4);
      final p2 = _FakePiece(2, peers: 2, subPieces: 4);
      final p3 = _FakePiece(3, peers: 7, subPieces: 4);
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2, 3: p3});
      for (final random in [false, true]) {
        final picked =
            selector.selectPiece('peerA', [0, 1, 2, 3], provider, random);
        expect(picked, same(p2), reason: 'random=$random must pick rarest');
      }
    });

    test('rarest-first: rarest piece listed last is still chosen', () {
      final selector = BasePieceSelector();
      final p0 = _FakePiece(0, peers: 8, subPieces: 4);
      final p1 = _FakePiece(1, peers: 6, subPieces: 4);
      final p2 = _FakePiece(2, peers: 1, subPieces: 4); // rarest, last
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2});
      expect(selector.selectPiece('peerA', [0, 1, 2], provider), same(p2));
      expect(selector.selectPiece('peerA', [0, 1, 2], provider, true),
          same(p2));
    });

    test('tie on peers -> prefers the piece with fewer remaining sub pieces',
        () {
      final selector = BasePieceSelector();
      // All equally rare (3 peers); p1 has the fewest sub pieces left.
      final p0 = _FakePiece(0, peers: 3, subPieces: 5);
      final p1 = _FakePiece(1, peers: 3, subPieces: 1);
      final p2 = _FakePiece(2, peers: 3, subPieces: 4);
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2});
      expect(selector.selectPiece('peerA', [0, 1, 2], provider), same(p1));
    });

    test('full tie (peers + sub pieces) is deterministic when random=false',
        () {
      final selector = BasePieceSelector();
      final p0 = _FakePiece(0, peers: 3, subPieces: 4);
      final p1 = _FakePiece(1, peers: 3, subPieces: 4);
      final p2 = _FakePiece(2, peers: 3, subPieces: 4);
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2});
      // Deterministic: the first fully-tied candidate, repeatable.
      final first = selector.selectPiece('peerA', [0, 1, 2], provider);
      expect(first, same(p0));
      for (var i = 0; i < 20; i++) {
        expect(selector.selectPiece('peerA', [0, 1, 2], provider), same(p0));
      }
    });

    test('full tie with random=true stays within the tied candidates', () {
      final selector = BasePieceSelector();
      final p0 = _FakePiece(0, peers: 3, subPieces: 4);
      final p1 = _FakePiece(1, peers: 3, subPieces: 4);
      final p2 = _FakePiece(2, peers: 3, subPieces: 4);
      // p3 is rarer; it must never be skipped in favour of a tie member,
      // and the tied random pick must never leak a non-candidate.
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2});
      final seen = <Piece?>{};
      for (var i = 0; i < 50; i++) {
        final picked =
            selector.selectPiece('peerA', [0, 1, 2], provider, true);
        expect([p0, p1, p2], contains(picked));
        seen.add(picked);
      }
      // The random tie-break should exercise more than a single candidate.
      expect(seen.length, greaterThan(1));
    });

    test('skips pieces unavailable to the peer when finding the rarest', () {
      final selector = BasePieceSelector();
      // The globally rarest piece (p0, 1 peer) is NOT available to peerA, so
      // it must be ignored; among the peer's candidates p2 (3 peers) is rarest.
      final p0 = _FakePiece(0, peers: 1, subPieces: 4, availableToPeer: false);
      final p1 = _FakePiece(1, peers: 8, subPieces: 4);
      final p2 = _FakePiece(2, peers: 3, subPieces: 4);
      final provider = _FakePieceProvider({0: p0, 1: p1, 2: p2});
      expect(selector.selectPiece('peerA', [0, 1, 2], provider), same(p2));
    });

    test('empty candidate set returns null', () {
      final selector = BasePieceSelector();
      final provider = _FakePieceProvider({});
      expect(selector.selectPiece('peerA', <int>[], provider), isNull);
      expect(selector.selectPiece('peerA', <int>[], provider, true), isNull);
    });
  });

  group('Peer wire protocol round-trip over loopback TCP', () {
    late ServerSocket server;
    late Peer local; // the "us" side that sends
    late Peer remote; // the side that receives and fires events
    final infoHash = List<int>.generate(20, (i) => i);

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final piecesNum = 40;

      final acceptedCompleter = Completer<Socket>();
      final sub = server.listen(acceptedCompleter.complete);

      final clientSocket = await Socket.connect(
          InternetAddress.loopbackIPv4, server.port);
      final serverSocket = await acceptedCompleter.future;
      await sub.cancel();

      final localAddr =
          CompactAddress(InternetAddress.loopbackIPv4, server.port);
      final remoteAddr =
          CompactAddress(clientSocket.address, clientSocket.port);

      local = Peer.newTCPPeer(
          'local-peer-id-aaaaaa', localAddr, infoHash, piecesNum, clientSocket);
      remote = Peer.newTCPPeer(
          'remote-peer-id-bbbbb', remoteAddr, infoHash, piecesNum, serverSocket);

      await local.connect();
      await remote.connect();
    });

    tearDown(() async {
      await local.dispose();
      await remote.dispose();
      await server.close();
    });

    test('handshake propagates peer id and reserved-bit capabilities',
        () async {
      final completer = Completer<String>();
      remote.onHandShake((source, remotePeerId, data) {
        if (!completer.isCompleted) completer.complete(remotePeerId);
      });
      local.sendHandShake();
      final got = await completer.future.timeout(Duration(seconds: 5));
      expect(got, equals('local-peer-id-aaaaaa'));
      // local enables fast + extended by default; remote must observe that.
      expect(remote.remoteEnableFastPeer, isTrue);
      expect(remote.remoteEnableExtended, isTrue);
    });

    test('choke / unchoke flips chokeMe and fires choke-change', () async {
      await _handshake(local, remote);
      // After handshake the local peer enabled fast ext; without it being a
      // fast peer on both sides the choke message path is plain.
      final events = <bool>[];
      final completer = Completer<void>();
      remote.onChokeChange((source, choke) {
        events.add(choke);
        if (events.length == 2 && !completer.isCompleted) completer.complete();
      });
      local.sendChoke(false); // unchoke
      local.sendChoke(true); // choke
      await completer.future.timeout(Duration(seconds: 5));
      expect(events, equals([false, true]));
    });

    test('interested / not-interested fires interested-change', () async {
      await _handshake(local, remote);
      final events = <bool>[];
      final completer = Completer<void>();
      remote.onInterestedChange((source, interested) {
        events.add(interested);
        if (events.length == 2 && !completer.isCompleted) completer.complete();
      });
      local.sendInterested(true);
      local.sendInterested(false);
      await completer.future.timeout(Duration(seconds: 5));
      expect(events, equals([true, false]));
    });

    test('have message delivers the piece index', () async {
      await _handshake(local, remote);
      final completer = Completer<List<int>>();
      remote.onHave((source, indices) {
        if (!completer.isCompleted) completer.complete(indices);
      });
      local.sendHave(17);
      final indices = await completer.future.timeout(Duration(seconds: 5));
      expect(indices, contains(17));
    });

    test('bitfield message reconstructs the remote bitfield', () async {
      await _handshake(local, remote);
      // Build a mixed bitfield (not all / not none) so it is sent verbatim.
      final bf = Bitfield.createEmptyBitfield(40);
      bf.setBit(1, true);
      bf.setBit(20, true);
      bf.setBit(39, true);

      final completer = Completer<Bitfield>();
      remote.onBitfield((source, bitfield) {
        if (!completer.isCompleted) completer.complete(bitfield);
      });
      local.sendBitfield(bf);
      final got = await completer.future.timeout(Duration(seconds: 5));
      expect(got.getBit(1), isTrue);
      expect(got.getBit(20), isTrue);
      expect(got.getBit(39), isTrue);
      expect(got.getBit(0), isFalse);
      expect(got.buffer, equals(bf.buffer));
    });

    test('request message delivers index/begin/length', () async {
      await _handshake(local, remote);
      // Sender: pretend the remote has unchoked us so sendRequest proceeds.
      local.chokeMe = false;
      // Receiver: it must have unchoked the requester, otherwise
      // _processRemoteRequest silently drops the request (BEP3 choke rule).
      remote.chokeRemote = false;
      final completer = Completer<List<int>>();
      remote.onRequest((source, index, begin, length) {
        if (!completer.isCompleted) completer.complete([index, begin, length]);
      });
      final ok = local.sendRequest(3, 16384, 16384);
      expect(ok, isTrue);
      final got = await completer.future.timeout(Duration(seconds: 5));
      expect(got, equals([3, 16384, 16384]));
    });

    test('port message delivers the listen port', () async {
      await _handshake(local, remote);
      final completer = Completer<int>();
      remote.onPortChange((source, port) {
        if (!completer.isCompleted) completer.complete(port);
      });
      local.sendPortChange(6881);
      final got = await completer.future.timeout(Duration(seconds: 5));
      expect(got, equals(6881));
    });
  });
}

/// Perform a handshake and wait until the receiving side has processed it,
/// so subsequent messages are framed after the 68-byte handshake.
Future<void> _handshake(Peer from, Peer to) async {
  final completer = Completer<void>();
  void handler(source, remotePeerId, data) {
    if (!completer.isCompleted) completer.complete();
  }

  to.onHandShake(handler);
  from.sendHandShake();
  await completer.future.timeout(Duration(seconds: 5));
  to.offHandShake(handler);
}

List<int> _asBytes(dynamic v) {
  if (v is Uint8List) return v;
  if (v is List<int>) return v;
  if (v is List) return v.cast<int>();
  if (v is String) return v.codeUnits;
  throw ArgumentError('cannot coerce $v to bytes');
}

// --- Fakes for the piece selector --------------------------------------------

class _FakePiece extends Piece {
  final int _peers;
  final int _subPieces;
  final bool _availableToPeer;
  _FakePiece(int index,
      {required int peers,
      required int subPieces,
      bool availableToPeer = true})
      : _peers = peers,
        _subPieces = subPieces,
        _availableToPeer = availableToPeer,
        super('hash$index', index, 16384, 16384);

  @override
  int get avalidatePeersCount => _peers;

  @override
  int get avalidateSubPieceCount => _subPieces;

  @override
  bool haveAvalidateSubPiece() => _subPieces > 0;

  @override
  bool containsAvalidatePeer(String id) => _availableToPeer && _peers > 0;
}

class _FakePieceProvider implements PieceProvider {
  final Map<int, Piece> _map;
  _FakePieceProvider(this._map);

  @override
  Piece? operator [](int index) => _map[index];

  @override
  int get length => _map.length;
}
