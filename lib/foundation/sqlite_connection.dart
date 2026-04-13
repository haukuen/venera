import 'package:sqlite3/sqlite3.dart';

Database openSqliteDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    configureSqliteConnection(db);
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}

void configureSqliteConnection(Database db) {
  db.execute('PRAGMA journal_mode = WAL;');
  final journalMode = db.select('PRAGMA journal_mode;').first['journal_mode'];
  if (journalMode is! String || journalMode.toLowerCase() != 'wal') {
    throw StateError('Failed to enable WAL mode.');
  }
  db.execute('PRAGMA synchronous = NORMAL;');
}
