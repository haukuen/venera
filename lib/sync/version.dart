/// Version tuple of the v2 sync protocol: `(HLC, per-device seq)`.
///
/// `seq` is a defensive tie-break for the case where HLC allocation bugs
/// produce the same HLC twice. It is unique per device and monotonically
/// increasing, so `(hlc, seq)` is a total order even if two operations share
/// an HLC.
library;

import 'hlc.dart';

class Version implements Comparable<Version> {
  const Version(this.hlc, this.seq);

  final Hlc hlc;
  final int seq;

  @override
  int compareTo(Version other) {
    final hlcComparison = hlc.compareTo(other.hlc);
    if (hlcComparison != 0) return hlcComparison;
    return seq.compareTo(other.seq);
  }

  bool operator <(Version other) => compareTo(other) < 0;

  bool operator <=(Version other) => compareTo(other) <= 0;

  bool operator >(Version other) => compareTo(other) > 0;

  bool operator >=(Version other) => compareTo(other) >= 0;

  Map<String, Object?> toJson() => {'hlc': hlc.encoded, 'seq': seq};

  static Version fromJson(Map<String, Object?> json) {
    final hlc = json['hlc'];
    final seq = json['seq'];
    if (hlc is! String || seq is! int || seq <= 0) {
      throw const FormatException('Invalid version json');
    }
    return Version(Hlc.parse(hlc), seq);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Version && hlc == other.hlc && seq == other.seq;

  @override
  int get hashCode => Object.hash(hlc, seq);

  @override
  String toString() => '${hlc.encoded}#$seq';
}

/// Returns the greater of two versions (`null` means absent).
Version? maxVersion(Version? a, Version? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a >= b ? a : b;
}
