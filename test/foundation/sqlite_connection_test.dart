import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void _initializeDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT);');
    db.execute('INSERT INTO items (value) VALUES ("seed");');
  } finally {
    db.dispose();
  }
}

void main() {
  test('openSqliteDatabase enables WAL and NORMAL synchronous mode', () {
    final dir = Directory.systemTemp.createTempSync('venera-sqlite-helper-');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    final db = openSqliteDatabase('${dir.path}/helper.db');
    addTearDown(db.dispose);

    final journalMode =
        db.select('PRAGMA journal_mode;').first['journal_mode'];
    final synchronous =
        db.select('PRAGMA synchronous;').first['synchronous'];

    expect((journalMode as String).toLowerCase(), 'wal');
    expect(synchronous, 1);
  });

  test('plain sqlite3 connections hit a read-then-write lock on the same file',
      () {
    final dir = Directory.systemTemp.createTempSync('venera-sqlite-lock-');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    final dbPath = '${dir.path}/lock.db';
    _initializeDatabase(dbPath);

    final reader = sqlite3.open(dbPath);
    final writer = sqlite3.open(dbPath);
    addTearDown(reader.dispose);
    addTearDown(writer.dispose);

    reader.execute('BEGIN;');
    reader.select('SELECT * FROM items;');

    expect(
      () => writer.execute('INSERT INTO items (value) VALUES ("locked");'),
      throwsA(
        isA<SqliteException>().having(
          (error) => error.resultCode,
          'resultCode',
          5,
        ),
      ),
    );
  });

  test('openSqliteDatabase avoids the same read-then-write lock on the file',
      () {
    final dir = Directory.systemTemp.createTempSync('venera-sqlite-lock-');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    final dbPath = '${dir.path}/lock.db';
    _initializeDatabase(dbPath);

    final reader = openSqliteDatabase(dbPath);
    final writer = openSqliteDatabase(dbPath);
    addTearDown(reader.dispose);
    addTearDown(writer.dispose);

    reader.execute('BEGIN;');
    reader.select('SELECT * FROM items;');

    expect(() => writer.execute('INSERT INTO items (value) VALUES ("ok");'),
        returnsNormally);
    expect(writer.select('SELECT count(*) AS count FROM items;').first['count'],
        2);
  });

  test('configureSqliteConnection rejects databases that cannot use WAL', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);

    expect(() => configureSqliteConnection(db), throwsStateError);
  });
}
