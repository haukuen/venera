/// Pure diff/apply logic between business adapters and the sync store.
///
/// Kept separate from [SyncV2Service] (which touches Appdata/managers) so the
/// core reconciliation rules are unit-testable with temporary SQLite files and
/// a real [SyncStore], without Flutter bindings.
library;

import '../op.dart';
import '../store.dart';
import 'sync_app_adapter.dart';

class SyncAppReconciler {
  SyncAppReconciler({
    required List<SyncAppAdapter> adapters,
    required Set<String> enabledDomains,
    this.clearableDomains = const <String>{},
  }) : adapters = List.unmodifiable(adapters),
       enabledDomains = Set.unmodifiable(enabledDomains);

  final List<SyncAppAdapter> adapters;
  final Set<String> enabledDomains;

  /// Domains where an empty local projection is represented by one clear
  /// cutoff instead of a delete per record.
  final Set<String> clearableDomains;

  /// Emits local business differences into [store].
  Future<void> reconcileLocal(SyncStore store) async {
    final desired = <String, AdapterRecord>{};
    for (final adapter in adapters) {
      if (adapter.domains.intersection(enabledDomains).isEmpty) continue;
      final records = await adapter.readLocalRecords();
      for (final record in records) {
        if (!enabledDomains.contains(record.domain)) continue;
        desired[record.identity] = record;
      }
    }

    final storedByDomain = <String, Map<String, StoredRecord>>{};
    for (final domain in enabledDomains) {
      final map = <String, StoredRecord>{};
      for (final record in await store.dumpRecords(domains: {domain})) {
        if (!record.visible) continue;
        map['${record.domain}|${record.key.encode()}|${record.field}'] = record;
      }
      storedByDomain[domain] = map;
    }

    for (final domain in enabledDomains) {
      final desiredForDomain = desired.values
          .where((record) => record.domain == domain)
          .toList();
      final stored = storedByDomain[domain]!;
      if (desiredForDomain.isEmpty &&
          clearableDomains.contains(domain) &&
          stored.isNotEmpty) {
        await store.emitClear(domain);
        continue;
      }

      for (final entry in stored.entries) {
        if (desired.containsKey(entry.key)) continue;
        final record = entry.value;
        await store.emit(
          domain: record.domain,
          key: record.key,
          field: record.field,
          kind: SyncOpKind.del,
        );
      }

      for (final record in desiredForDomain) {
        final existing = stored[record.identity];
        if (existing != null && dataEquals(existing.data, record.data)) {
          continue;
        }
        await store.emit(
          domain: record.domain,
          key: record.key,
          field: record.field,
          kind: record.kind,
          data: record.data,
        );
      }
    }
  }

  /// Projects merged store state back into the business databases.
  ///
  /// A domain with no store knowledge at all is skipped: an empty store may
  /// simply mean "never seeded", and adapters such as AuthAdapter/\
  /// FavoritesAdapter would otherwise delete live local rows. Deletions are
  /// represented by tombstones/clear cutoffs, which make `dumpRecords` /
  /// `dumpClears` non-empty even when everything is invisible.
  Future<void> applyRemote(SyncStore store) async {
    for (final adapter in adapters) {
      if (adapter.domains.intersection(enabledDomains).isEmpty) continue;
      final records = await store.dumpRecords(domains: adapter.domains);
      final clears = await store.dumpClears(domains: adapter.domains);
      if (records.isEmpty && clears.isEmpty) continue;
      await adapter.applyRemote(store);
    }
  }

  static bool dataEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key)) return false;
        if (!dataEquals(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!dataEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
