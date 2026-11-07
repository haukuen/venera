/// Pure-Dart core of the Venera v2 sync protocol.
///
/// This library deliberately has no Flutter imports so it can be tested in
/// `flutter test` without a desktop/display and reused by any backend.
library;

export 'blob_sync.dart';
export 'domains.dart';
export 'engine.dart';
export 'fake_transport.dart';
export 'hlc.dart';
export 'key_codec.dart';
export 'op.dart';
export 'snapshot.dart';
export 'sqlite_store.dart';
export 'store.dart';
export 'transport.dart';
export 'version.dart';
