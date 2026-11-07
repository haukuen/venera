import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/hlc.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/snapshot.dart';
import 'package:venera/sync/version.dart';

const _deviceA = 'aaaaaaaa-1111-2222-3333-444444444444';
const _deviceB = 'bbbbbbbb-1111-2222-3333-444444444444';

void main() {
  group('Hlc', () {
    test('formats fixed width and parses back', () {
      final hlc = Hlc(ms: 1762345678901, counter: 3, deviceId: _deviceA);
      expect(hlc.encoded, '1762345678901:000003:$_deviceA');
      expect(Hlc.parse(hlc.encoded), hlc);
      expect(
        Hlc.parse(Hlc.format(1, 0, _deviceA)).encoded,
        '0000000000001:000000:$_deviceA',
      );
    });

    test('counter 9 orders before counter 10 (the variable-width bug)', () {
      final nine = Hlc(ms: 1762345678901, counter: 9, deviceId: _deviceA);
      final ten = Hlc(ms: 1762345678901, counter: 10, deviceId: _deviceA);
      expect(nine < ten, isTrue);
      expect(nine.encoded.compareTo(ten.encoded) < 0, isTrue);
      expect(nine.compareTo(ten) < 0, isTrue);
    });

    test('device id breaks ties', () {
      final a = Hlc(ms: 100, counter: 0, deviceId: _deviceA);
      final b = Hlc(ms: 100, counter: 0, deviceId: _deviceB);
      expect(a.compareTo(b), isNot(0));
      expect(a == b, isFalse);
    });

    test('rejects invalid encodings', () {
      expect(() => Hlc.parse('nope'), throwsFormatException);
      expect(() => Hlc.parse('1:2:short'), throwsFormatException);
      expect(() => Hlc.parse('1762345678901:1:../evil'), throwsFormatException);
      expect(() => Hlc.format(-1, 0, _deviceA), throwsArgumentError);
      expect(() => Hlc.format(1, -1, _deviceA), throwsArgumentError);
      expect(() => Hlc.format(1, 0, 'UPPER'), throwsArgumentError);
    });

    test('json roundtrip', () {
      final hlc = Hlc(ms: 5, counter: 6, deviceId: _deviceB);
      expect(Hlc.fromJson(hlc.toJson()), hlc);
      expect(Hlc.fromJson(hlc.encoded), hlc);
    });
  });

  group('HlcClock', () {
    test('tick is monotonic and observes remote clocks', () {
      final fixed = DateTime.fromMillisecondsSinceEpoch(1000);
      final clock = HlcClock(deviceId: _deviceA, now: () => fixed);
      final first = clock.tick();
      final second = clock.tick();
      expect(first < second, isTrue);

      clock.observe(Hlc(ms: 9999999999999, counter: 0, deviceId: _deviceB));
      final afterObserve = clock.tick();
      expect(
        afterObserve > Hlc(ms: 9999999999999, counter: 0, deviceId: _deviceB),
        isTrue,
      );
    });

    test('clock rollback keeps monotonic', () {
      var now = DateTime.fromMillisecondsSinceEpoch(5000);
      final clock = HlcClock(deviceId: _deviceA, now: () => now);
      final first = clock.tick();
      now = DateTime.fromMillisecondsSinceEpoch(1000);
      final second = clock.tick();
      expect(first <= second, isTrue);
    });

    test('counter overflow bumps milliseconds', () {
      final fixed = DateTime.fromMillisecondsSinceEpoch(1000);
      final clock = HlcClock(
        deviceId: _deviceA,
        now: () => fixed,
        ms: 1000,
        counter: Hlc.maxCounter,
      );
      final hlc = clock.tick();
      expect(hlc.ms, 1001);
      expect(hlc.counter, 0);
    });

    test('json roundtrip preserves state', () {
      final clock = HlcClock(deviceId: _deviceA, ms: 42, counter: 3);
      final restored = HlcClock.fromJson(clock.toJson());
      expect(restored.deviceId, _deviceA);
      expect(restored.ms, 42);
      expect(restored.counter, 3);
    });
  });

  group('Version', () {
    test('compares HLC then seq', () {
      final a = Version(Hlc(ms: 1, counter: 0, deviceId: _deviceA), 1);
      final a2 = Version(Hlc(ms: 1, counter: 0, deviceId: _deviceA), 2);
      final b = Version(Hlc(ms: 2, counter: 0, deviceId: _deviceA), 1);
      expect(a < a2, isTrue);
      expect(a2 < b, isTrue);
      expect(maxVersion(a, b), b);
      expect(maxVersion(a, null), a);
      expect(maxVersion(null, null), isNull);
    });

    test('json roundtrip and validation', () {
      final version = Version(Hlc(ms: 3, counter: 4, deviceId: _deviceA), 7);
      expect(Version.fromJson(version.toJson()), version);
      expect(
        () => Version.fromJson({'hlc': version.hlc.encoded, 'seq': 0}),
        throwsFormatException,
      );
    });
  });

  group('SyncKey', () {
    test('encodes as JSON array and roundtrips separator-y segments', () {
      final key = SyncKey([
        'folder/a',
        'x@y',
        '#1',
        '"quote"',
        r'back\slash',
        '中文',
      ]);
      final encoded = key.encode();
      expect(encoded.startsWith('['), isTrue);
      expect(SyncKey.decode(encoded), key);
      expect(encoded.contains('"folder/a"'), isTrue);
    });

    test('does not collide with separator concatenation', () {
      final a = SyncKey(['a/b', 'c']);
      final b = SyncKey(['a', 'b/c']);
      expect(a == b, isFalse);
      expect(a.encode(), isNot(b.encode()));
    });

    test('rejects invalid payloads', () {
      expect(() => SyncKey(const []), throwsArgumentError);
      expect(() => SyncKey.decode('"not-a-list"'), throwsFormatException);
      expect(() => SyncKey.decode('["ok", 1]'), throwsFormatException);
      expect(() => SyncKey.decode('{'), throwsFormatException);
      expect(
        () => SyncKey(List.filled(SyncKey.maxParts + 1, 'x')),
        throwsArgumentError,
      );
    });
  });

  group('SyncOp', () {
    SyncOp op({
      SyncOpKind kind = SyncOpKind.upsert,
      SyncKey? key,
      Map<String, Object?>? data,
      int seq = 2,
    }) => SyncOp(
      deviceId: _deviceA,
      seq: seq,
      version: Version(Hlc(ms: 1000, counter: 0, deviceId: _deviceA), seq),
      domain: 'history',
      key: key ?? SyncKey(['abc', '1']),
      field: 'progress',
      kind: kind,
      data: data,
    );

    test('wire json roundtrip for upsert', () {
      final original = op(data: {'ep': 12, 'page': 3});
      final decoded = SyncOp.fromJson(original.toJson());
      expect(decoded.deviceId, original.deviceId);
      expect(decoded.seq, original.seq);
      expect(decoded.version, original.version);
      expect(decoded.domain, original.domain);
      expect(decoded.key, original.key);
      expect(decoded.field, original.field);
      expect(decoded.kind, original.kind);
      expect(decoded.data, original.data);
    });

    test('set ops and clear ops encode correctly', () {
      final add = op(kind: SyncOpKind.add, data: null);
      expect(add.toJson()['op'], 'add');
      expect(add.toJson()['k'], ['abc', '1']);

      final clear = SyncOp(
        deviceId: _deviceA,
        seq: 9,
        version: Version(Hlc(ms: 1, counter: 0, deviceId: _deviceA), 9),
        domain: 'history',
        key: null,
        field: '',
        kind: SyncOpKind.clear,
      );
      final json = clear.toJson();
      expect(json['k'], '*');
      final decoded = SyncOp.fromJson(json);
      expect(decoded.kind, SyncOpKind.clear);
      expect(decoded.key, isNull);
    });

    test('rejects malformed ops', () {
      expect(
        () => SyncOp(
          deviceId: _deviceA,
          seq: 0,
          version: Version(Hlc(ms: 1, counter: 0, deviceId: _deviceA), 1),
          domain: 'history',
          key: SyncKey(['x']),
          field: '',
          kind: SyncOpKind.upsert,
        ),
        throwsArgumentError,
      );
      expect(
        () => SyncOp(
          deviceId: _deviceA,
          seq: 1,
          version: Version(Hlc(ms: 1, counter: 0, deviceId: _deviceB), 1),
          domain: 'history',
          key: SyncKey(['x']),
          field: '',
          kind: SyncOpKind.upsert,
        ),
        throwsArgumentError,
      );
      expect(
        () => SyncOp(
          deviceId: _deviceA,
          seq: 1,
          version: Version(Hlc(ms: 1, counter: 0, deviceId: _deviceA), 1),
          domain: 'history domain',
          key: SyncKey(['x']),
          field: '',
          kind: SyncOpKind.upsert,
        ),
        throwsArgumentError,
      );
      expect(
        () => SyncOp.fromJson({'v': 1, 'dev': _deviceA}),
        throwsFormatException,
      );
    });
  });

  group('SyncOpCodec', () {
    List<SyncOp> batch() => [
      for (var seq = 1; seq <= 3; seq++)
        SyncOp(
          deviceId: _deviceA,
          seq: seq,
          version: Version(
            Hlc(ms: 1000 + seq, counter: 0, deviceId: _deviceA),
            seq,
          ),
          domain: 'readLater',
          key: SyncKey(['comic$seq']),
          field: '',
          kind: SyncOpKind.add,
        ),
    ];

    test('encode/decode roundtrip with gzip', () {
      final ops = batch();
      final bytes = SyncOpCodec.encode(ops);
      expect(bytes.length, greaterThan(0));
      final decoded = SyncOpCodec.decode(
        bytes,
        expectedDeviceId: _deviceA,
        lo: 1,
        hi: 3,
      );
      expect(decoded.length, 3);
      expect(decoded.first.seq, 1);
      expect(decoded.last.seq, 3);
    });

    test('rejects wrong device, range, holes and corruption', () {
      final bytes = SyncOpCodec.encode(batch());
      expect(
        () =>
            SyncOpCodec.decode(bytes, expectedDeviceId: _deviceB, lo: 1, hi: 3),
        throwsFormatException,
      );
      expect(
        () =>
            SyncOpCodec.decode(bytes, expectedDeviceId: _deviceA, lo: 2, hi: 4),
        throwsFormatException,
      );
      expect(
        () => SyncOpCodec.decode(
          Uint8List.fromList([1, 2, 3, 4]),
          expectedDeviceId: _deviceA,
          lo: 1,
          hi: 3,
        ),
        throwsA(anything),
      );

      final raw = utf8.encode(
        '${jsonEncode(batch().first.toJson())}\n'
        '${jsonEncode(batch().last.toJson())}',
      );
      final gzipped = Uint8List.fromList(GZipCodec().encode(raw));
      expect(
        () => SyncOpCodec.decode(
          gzipped,
          expectedDeviceId: _deviceA,
          lo: 1,
          hi: 3,
        ),
        throwsFormatException,
      );
    });

    test('decodes first line', () {
      final bytes = SyncOpCodec.encode(batch());
      final first = SyncOpCodec.decodeFirstLine(bytes);
      expect(first['dev'], _deviceA);
      expect(first['seq'], 1);
    });
  });

  group('Snapshot', () {
    SnapshotInfo info() => SnapshotInfo(
      deviceId: _deviceA,
      hlc: Hlc(ms: 5000, counter: 0, deviceId: _deviceA),
      rangeLo: 1,
      rangeHi: 7,
      applied: {_deviceA: 7, _deviceB: 3},
      domains: {'history', 'readLater'},
    );

    ParsedSnapshot sample() => ParsedSnapshot(
      info: info(),
      clears: {
        'history': Version(Hlc(ms: 4000, counter: 0, deviceId: _deviceA), 5),
      },
      records: [
        SnapshotRecord(
          domain: 'history',
          key: SyncKey(['abc', '1']),
          field: 'progress',
          version: Version(Hlc(ms: 3000, counter: 0, deviceId: _deviceA), 2),
          data: {'ep': 1},
        ),
        SnapshotRecord(
          domain: 'readLater',
          key: SyncKey(['abc']),
          field: '',
          version: Version(Hlc(ms: 3001, counter: 0, deviceId: _deviceB), 1),
          deletedVersion: Version(
            Hlc(ms: 3002, counter: 0, deviceId: _deviceB),
            2,
          ),
        ),
      ],
    );

    test('info json roundtrip', () {
      final original = info();
      final restored = SnapshotInfo.fromJson(original.toJson());
      expect(restored.deviceId, original.deviceId);
      expect(restored.hlc, original.hlc);
      expect(restored.rangeLo, original.rangeLo);
      expect(restored.rangeHi, original.rangeHi);
      expect(restored.applied, original.applied);
      expect(restored.domains, original.domains);
    });

    test('snapshot encode/decode roundtrip incl. tombstone and clear', () {
      final parsed = sample();
      final bytes = SnapshotCodec.encode(
        parsed.info,
        parsed.clears,
        parsed.records,
      );
      final decoded = SnapshotCodec.decode(bytes, expectedDeviceId: _deviceA);
      expect(decoded.info.applied, parsed.info.applied);
      expect(decoded.clears.length, 1);
      expect(decoded.records.length, 2);
      expect(decoded.records.first.data, {'ep': 1});
      expect(decoded.records.last.visible, isFalse);
    });

    test('rejects device mismatch and undeclared domains', () {
      final parsed = sample();
      final bytes = SnapshotCodec.encode(
        parsed.info,
        parsed.clears,
        parsed.records,
      );
      expect(
        () => SnapshotCodec.decode(bytes, expectedDeviceId: _deviceB),
        throwsFormatException,
      );

      final badRecord = SnapshotRecord(
        domain: 'setting',
        key: SyncKey(['theme']),
        field: '',
        version: Version(Hlc(ms: 1, counter: 0, deviceId: _deviceA), 1),
        data: {'value': 'dark'},
      );
      final badBytes = SnapshotCodec.encode(parsed.info, parsed.clears, [
        badRecord,
      ]);
      expect(
        () => SnapshotCodec.decode(badBytes, expectedDeviceId: _deviceA),
        throwsFormatException,
      );
    });
  });

  group('resolveSyncDeviceId', () {
    test('passes through a grammar-conformant id (trimmed)', () {
      expect(resolveSyncDeviceId(_deviceA, 'seed'), _deviceA);
      expect(resolveSyncDeviceId('  $_deviceA  ', 'seed'), _deviceA);
    });

    test('derives a deterministic, grammar-conformant fallback', () {
      for (final raw in <Object?>['not a device id', 'UPPER', null, '']) {
        final id = resolveSyncDeviceId(raw, 'D:/data/path');
        expect(hlcDeviceIdRegExp.hasMatch(id), isTrue, reason: '$raw -> $id');
        expect(resolveSyncDeviceId(raw, 'D:/data/path'), id);
      }
    });
  });
}
