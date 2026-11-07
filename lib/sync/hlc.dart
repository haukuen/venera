/// Hybrid Logical Clock (HLC) implementation for the v2 sync protocol.
///
/// Canonical encoding: 13-digit zero-padded milliseconds, colon,
/// 6-digit zero-padded counter, colon, device id — e.g.
/// `1762345678901:000003:a1b2c3d4`.
///
/// The encoding is deliberately fixed width so that, and only so that, its
/// byte-wise order equals the numeric `(ms, counter, deviceId)` order. Never
/// compare un-normalized HLC strings.
library;

import 'dart:convert';

/// Allowed device id character set: lowercase hex, separated by `-`.
final RegExp hlcDeviceIdRegExp = RegExp(r'^[0-9a-f-]{8,64}$');

final RegExp _hlcRegExp = RegExp(r'^(\d{13}):(\d{6}):([0-9a-f-]{8,64})$');

/// A single hybrid logical clock value.
class Hlc implements Comparable<Hlc> {
  const Hlc({required this.ms, required this.counter, required this.deviceId});

  final int ms;
  final int counter;
  final String deviceId;

  static const int maxCounter = 999999;
  static const int maxMs = 9999999999999;

  /// Formats [ms], [counter] and [deviceId] into the canonical encoding.
  static String format(int ms, int counter, String deviceId) {
    if (ms < 0 || ms > maxMs) {
      throw ArgumentError.value(ms, 'ms', 'HLC ms out of range');
    }
    if (counter < 0 || counter > maxCounter) {
      throw ArgumentError.value(counter, 'counter', 'HLC counter out of range');
    }
    if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
    }
    return '${ms.toString().padLeft(13, '0')}:'
        '${counter.toString().padLeft(6, '0')}:$deviceId';
  }

  /// Parses the canonical encoding, throwing [FormatException] when invalid.
  static Hlc parse(String value) {
    final match = _hlcRegExp.firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid HLC', value);
    }
    return Hlc(
      ms: int.parse(match.group(1)!),
      counter: int.parse(match.group(2)!),
      deviceId: match.group(3)!,
    );
  }

  static Hlc? tryParse(String value) {
    try {
      return parse(value);
    } on FormatException {
      return null;
    }
  }

  String get encoded => format(ms, counter, deviceId);

  @override
  int compareTo(Hlc other) {
    final msComparison = ms.compareTo(other.ms);
    if (msComparison != 0) return msComparison;
    final counterComparison = counter.compareTo(other.counter);
    if (counterComparison != 0) return counterComparison;
    return deviceId.compareTo(other.deviceId);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;

  bool operator <=(Hlc other) => compareTo(other) <= 0;

  bool operator >(Hlc other) => compareTo(other) > 0;

  bool operator >=(Hlc other) => compareTo(other) >= 0;

  Map<String, Object?> toJson() => {'hlc': encoded};

  static Hlc fromJson(Object? json) {
    if (json is String) return parse(json);
    if (json is Map && json['hlc'] is String) {
      return parse(json['hlc'] as String);
    }
    throw FormatException('Invalid HLC json', json);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Hlc &&
          ms == other.ms &&
          counter == other.counter &&
          deviceId == other.deviceId;

  @override
  int get hashCode => Object.hash(ms, counter, deviceId);

  @override
  String toString() => encoded;
}

/// A persisted HLC generator for one device.
///
/// Allocation is not synchronized by this class. Callers must serialize
/// [tick] calls (and the persistence of the returned value) in the same
/// write transaction, see the protocol document §5.3.
class HlcClock {
  HlcClock({
    required this.deviceId,
    DateTime Function()? now,
    int ms = 0,
    int counter = 0,
  }) : _now = now ?? DateTime.now,
       _ms = ms,
       _counter = counter {
    if (!hlcDeviceIdRegExp.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Invalid device id');
    }
    if (ms < 0 || ms > Hlc.maxMs) {
      throw ArgumentError.value(ms, 'ms', 'HLC ms out of range');
    }
    if (counter < 0 || counter > Hlc.maxCounter) {
      throw ArgumentError.value(counter, 'counter', 'HLC counter out of range');
    }
  }

  final String deviceId;
  final DateTime Function() _now;

  int _ms;
  int _counter;

  int get ms => _ms;

  int get counter => _counter;

  Hlc get last => Hlc(ms: _ms, counter: _counter, deviceId: deviceId);

  /// Advances the clock for a local event and returns the new HLC.
  Hlc tick({DateTime? at}) {
    final nowMs = (at ?? _now()).millisecondsSinceEpoch;
    var physical = nowMs > _ms ? nowMs : _ms;
    var nextCounter = physical == _ms ? _counter + 1 : 0;
    if (nextCounter > Hlc.maxCounter) {
      physical += 1;
      nextCounter = 0;
    }
    _ms = physical;
    _counter = nextCounter;
    return last;
  }

  /// Observes a remote HLC so that the next local [tick] is strictly greater.
  void observe(Hlc remote) {
    if (remote.ms > _ms) {
      _ms = remote.ms;
      _counter = remote.counter;
    } else if (remote.ms == _ms && remote.counter > _counter) {
      _counter = remote.counter;
    }
  }

  HlcClock copyWith({DateTime Function()? now}) => HlcClock(
    deviceId: deviceId,
    now: now ?? _now,
    ms: _ms,
    counter: _counter,
  );

  Map<String, Object?> toJson() => {
    'device': deviceId,
    'ms': _ms,
    'counter': _counter,
  };

  static HlcClock fromJson(
    Map<String, Object?> json, {
    DateTime Function()? now,
  }) {
    final device = json['device'];
    final ms = json['ms'];
    final counter = json['counter'];
    if (device is! String || ms is! int || counter is! int) {
      throw const FormatException('Invalid HLC clock json');
    }
    return HlcClock(deviceId: device, now: now, ms: ms, counter: counter);
  }

  @override
  String toString() => 'HlcClock(${toJson()})';
}

/// Compact JSON encoding of an HLC clock, used in logs/tests.
String encodeHlcClock(HlcClock clock) => jsonEncode(clock.toJson());

/// Resolves the sync device id from the stored setting.
///
/// Returns [raw] when it already satisfies the device-id grammar (a UUID,
/// for example). Otherwise derives a deterministic, grammar-conformant id
/// from [fallbackSeed]. The grammar allows hex digits and dashes only, so
/// the fallback is pure hex: an arbitrary prefix such as `device-` would be
/// rejected by [HlcClock] and break sync startup entirely.
String resolveSyncDeviceId(Object? raw, String fallbackSeed) {
  if (raw is String) {
    final trimmed = raw.trim();
    if (hlcDeviceIdRegExp.hasMatch(trimmed)) return trimmed;
  }
  final hash = fallbackSeed.codeUnits
      .fold<int>(0x5eed, (value, unit) => (value * 31 + unit) & 0x7fffffff)
      .toRadixString(16)
      .padLeft(8, '0');
  return '$hash$hash';
}
