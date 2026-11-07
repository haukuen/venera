/// App integration contract for the v2 sync engine (M1).
///
/// The app does not hook every manager write path. Instead each adapter
/// projects one or more business SQLite tables into the generic [SyncStore]
/// (diff-based reconciliation) and projects merged remote state back.
///
/// This keeps all existing write paths (including the history isolate and
/// history retention cleanup) working unchanged: the next reconciliation
/// detects the difference and emits it. Adapters must be idempotent:
/// `readLocalRecords` is called repeatedly, and `applyRemote` may be called
/// after any merge.
library;

import '../key_codec.dart';
import '../op.dart';
import '../store.dart';
import 'business_db_token.dart';

/// One desired local record, as projected from a business database.
class AdapterRecord {
  const AdapterRecord({
    required this.domain,
    required this.key,
    this.field = '',
    this.kind = SyncOpKind.upsert,
    this.data,
  });

  final String domain;
  final SyncKey key;
  final String field;

  /// `upsert` for registers, `add` for set members.
  final SyncOpKind kind;

  /// JSON payload. `null` for pure set membership.
  final Map<String, Object?>? data;

  String get identity => '$domain|${key.encode()}|$field';

  @override
  String toString() => 'AdapterRecord($identity, ${kind.name})';
}

abstract class SyncAppAdapter {
  /// Domains written/read by this adapter. The service uses this to filter the
  /// engine and to decide which store records to apply.
  Set<String> get domains;

  /// Projects the current business state into adapter records.
  ///
  /// Must not mutate anything. Missing previously-known records are detected
  /// by the service (store has a visible record but the adapter no longer
  /// returns it) and emitted as deletes by the service — unless
  /// [retainsDomainRecords] says the local projection cannot be trusted, see
  /// [BusinessDbToken].
  Future<List<AdapterRecord>> readLocalRecords();

  /// Projects the merged store state for [domains] back into the business
  /// database. Implementations must be atomic and must only touch their own
  /// domains. After writing, they should call [reload].
  Future<void> applyRemote(SyncStore store);

  /// Reloads manager caches / notifies UI after [applyRemote] changed the
  /// business database. Should be a no-op when nothing changed.
  Future<void> reload();

  /// Whether the reconciler must keep a stored record whose local projection
  /// is currently absent.
  ///
  /// For most adapters an absent projection is a deliberate local deletion
  /// and the default (`false`) lets reconciliation tombstone it. Adapters whose
  /// local storage can be *unreadable* (not deleted) — e.g. a source login
  /// sidecar that failed validation — return `true` so a transient read
  /// failure is never propagated as a deletion to every other device.
  /// [AdapterRecord]s previously emitted by this adapter are passed for
  /// reference; explicit deletions are represented by the adapter itself
  /// emitting a delete, which this hook does not intercept.
  bool retainsMissingRecord(StoredRecord record) => false;

  /// Whether the stored records of [domain] must currently be kept instead of
  /// being diffed against the local projection.
  ///
  /// Diff-based deletion detection is only safe when the local business
  /// database is the same instance the last projection was written to.
  /// Implementations return `true` while the local data cannot prove that
  /// (unreadable file, missing table, or a recreated database file — see
  /// [BusinessDbToken]). The reconciler then keeps the stored records of the
  /// domain (no deletes, no clear cutoffs) and reports the domain to the
  /// service, which re-projects the merged state: lost local data is
  /// restored and the identity token re-aligns. Defaults to `false` (the
  /// projection is always trusted).
  ///
  /// A domain may be claimed by several adapters; the reconciler retains the
  /// domain if *any* of them returns `true`.
  Future<bool> retainsDomainRecords(SyncStore store, String domain) async =>
      false;
}

/// Optional capability for adapters that hold long-lived resources (e.g. the
/// auth adapter's lazily opened SQLite connection).
///
/// The service calls [dispose] when the engine is rebuilt or shut down;
/// without it, every rebuild leaks the held file handle. Adapters that open
/// per-operation connections need not implement it.
abstract interface class SyncDisposableAdapter {
  void dispose();
}

/// Optional capability for adapters that reference content-addressed blobs
/// (e.g. comic source `.js` files, protocol §6.3).
///
/// The service calls [ensureBlobsUploaded] after local reconciliation and
/// before push/seed, so `readLocalRecords` stays side-effect free while the
/// referenced blobs are guaranteed to exist remotely before the op is uploaded.
abstract interface class SyncBlobAdapter {
  /// Uploads every local blob that a record references.
  ///
  /// Returns the number of blobs that could **not** be uploaded. The caller
  /// must treat a non-zero result as a failed push: a record whose blob is
  /// missing remotely can never be repaired later, because the record itself
  /// does not change again.
  Future<int> ensureBlobsUploaded();
}
