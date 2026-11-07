/// Identity token proving that a business database file is the same instance
/// an adapter last projected into.
///
/// Deletion detection in the reconciler is diff-based: records that are
/// visible in the store but absent from the local projection are emitted as
/// deletions. That inference is only safe when the local database is the same
/// file the projection was written to. If the file was deleted (its manager
/// recreates an empty schema on the next start) or cannot be read, its
/// emptiness must never be propagated as a deletion to every other device.
///
/// The token is a random nonzero 31-bit integer stored in the SQLite
/// `user_version` header field:
///
///  * it lives and dies with the file — a recreated file loses it, which is
///    exactly the mismatch signal;
///  * it is invisible to table-name based logic (the favorites manager and
///    adapter enumerate tables to find folders);
///  * the business managers never touch it.
///
/// The adapter mirrors the token of the last successful projection into the
/// sync store meta ([storeMetaKey]). While the file token and the mirrored
/// token disagree (including "file has none"), the local projection must be
/// treated as unreadable rather than empty; re-projecting the merged store
/// state restores the data and re-aligns the tokens.
///
/// Adapters that project the same file (history + image favorites) must share
/// one [storeMetaKey], because the token is a property of the file.
library;

import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../store.dart';

class BusinessDbToken {
  BusinessDbToken({required this.storeMetaKey});

  /// Store-meta key holding the token of the last successful projection.
  final String storeMetaKey;

  /// Reads the token stored in [db]; `null` when the file has none (fresh or
  /// recreated) or cannot be read.
  int? read(Database db) {
    try {
      final value = db.select('PRAGMA user_version;').first.values.first;
      if (value is int && value != 0) return value;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Allocates and writes the token if [db] has none yet.
  ///
  /// Must run inside the same transaction that writes the projected state,
  /// so the token can never describe data that was not committed.
  void write(Database db) {
    if (read(db) != null) return;
    final token = Random.secure().nextInt(1 << 30) + 1;
    // PRAGMA values cannot be parameterized; the interpolated value is a
    // plain int, never user input.
    db.execute('PRAGMA user_version = $token;');
  }

  /// Mirrors [token] into the sync store meta after a successful projection.
  ///
  /// A crash between the business transaction and this call leaves the two
  /// sides mismatched, which only errs toward keeping the stored records
  /// until the next projection re-aligns them.
  Future<void> mirror(SyncStore store, int? token) async {
    final encoded = token?.toString();
    final current = await store.getMeta(storeMetaKey);
    if (current == encoded) return;
    await store.setMeta(storeMetaKey, encoded);
  }

  /// Whether the local projection of the file can be trusted as a deletion
  /// signal: it was readable and its token matches the last projected one.
  ///
  /// Both sides unset means the file was never projected — a legitimate
  /// primary device whose deletions must keep propagating.
  bool matchesProjection(int? fileToken, String? projectedToken) {
    if (fileToken == null && projectedToken == null) return true;
    return fileToken?.toString() == projectedToken;
  }
}
