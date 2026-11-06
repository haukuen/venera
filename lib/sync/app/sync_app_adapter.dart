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
  /// returns it) and emitted as deletes by the service.
  Future<List<AdapterRecord>> readLocalRecords();

  /// Projects the merged store state for [domains] back into the business
  /// database. Implementations must be atomic and must only touch their own
  /// domains. After writing, they should call [reload].
  Future<void> applyRemote(SyncStore store);

  /// Reloads manager caches / notifies UI after [applyRemote] changed the
  /// business database. Should be a no-op when nothing changed.
  Future<void> reload();
}

/// Optional capability for adapters that reference content-addressed blobs
/// (e.g. comic source `.js` files, protocol §6.3).
///
/// The service calls [ensureBlobsUploaded] after local reconciliation and
/// before push/seed, so `readLocalRecords` stays side-effect free while the
/// referenced blobs are guaranteed to exist remotely before the op is uploaded.
abstract interface class SyncBlobAdapter {
  Future<void> ensureBlobsUploaded();
}
