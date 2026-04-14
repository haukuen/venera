import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/sqlite_connection.dart';

class ReadLaterItem implements Comic {
  @override
  final String id;
  final ComicType type;
  @override
  final String title;
  @override
  final String? subtitle;
  @override
  final String cover;
  @override
  final String sourceKey;
  final DateTime addedTime;

  ReadLaterItem({
    required this.id,
    required this.type,
    required this.title,
    this.subtitle,
    required this.cover,
    required this.sourceKey,
    required this.addedTime,
  });

  ReadLaterItem.fromRow(Row row)
      : id = row["id"],
        type = ComicType(row["type"]),
        title = row["title"],
        subtitle = row["subtitle"],
        cover = row["cover"],
        sourceKey = row["source_key"],
        addedTime = DateTime.fromMillisecondsSinceEpoch(row["added_time"]);

  factory ReadLaterItem.fromComic(Comic comic) {
    return ReadLaterItem(
      id: comic.id,
      type: ComicType(
          comic.sourceKey == 'local' ? 0 : comic.sourceKey.hashCode),
      title: comic.title,
      subtitle: comic.subtitle,
      cover: comic.cover,
      sourceKey: comic.sourceKey,
      addedTime: DateTime.now(),
    );
  }

  @override
  String get description => subtitle ?? '';

  @override
  int? get maxPage => null;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  bool operator ==(Object other) =>
      other is ReadLaterItem && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(id, type);

  @override
  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "type": type.value,
      "title": title,
      "subtitle": subtitle,
      "cover": cover,
      "sourceKey": sourceKey,
      "addedTime": addedTime.millisecondsSinceEpoch,
    };
  }
}

class ReadLaterManager with ChangeNotifier {
  static ReadLaterManager? _cache;

  ReadLaterManager._create();

  factory ReadLaterManager() =>
      _cache ?? (_cache = ReadLaterManager._create());

  late Database _db;
  late String _dbPath;

  bool isInitialized = false;

  int get count {
    if (!isInitialized) return 0;
    var res = _db.select("SELECT count(*) FROM read_later;");
    return res.first[0] as int;
  }

  Future<void> init() async {
    if (isInitialized) return;
    _dbPath = "${App.dataPath}/read_later.db";
    _db = openSqliteDatabase(_dbPath);
    _db.execute("""
      CREATE TABLE IF NOT EXISTS read_later (
        id TEXT NOT NULL,
        type INTEGER NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        cover TEXT NOT NULL,
        source_key TEXT NOT NULL,
        added_time INTEGER NOT NULL,
        PRIMARY KEY (id, type)
      );
    """);
    HistoryManager().addListener(_onHistoryChanged);
    isInitialized = true;
    notifyListeners();
  }

  void _onHistoryChanged() {
    var cachedHistories = HistoryManager().cachedHistories;
    var removed = false;
    for (var history in cachedHistories.values) {
      if (_existsInDb(history.id, history.type)) {
        _removeFromDb(history.id, history.type);
        removed = true;
      }
    }
    if (removed) {
      notifyListeners();
    }
  }

  bool _existsInDb(String id, ComicType type) {
    var res = _db.select(
      "SELECT 1 FROM read_later WHERE id = ? AND type = ?;",
      [id, type.value],
    );
    return res.isNotEmpty;
  }

  void _removeFromDb(String id, ComicType type) {
    _db.execute(
      "DELETE FROM read_later WHERE id = ? AND type = ?;",
      [id, type.value],
    );
  }

  void add(ReadLaterItem item) {
    _db.execute(
      "INSERT OR IGNORE INTO read_later (id, type, title, subtitle, cover, source_key, added_time) VALUES (?, ?, ?, ?, ?, ?, ?);",
      [
        item.id,
        item.type.value,
        item.title,
        item.subtitle,
        item.cover,
        item.sourceKey,
        item.addedTime.millisecondsSinceEpoch,
      ],
    );
    notifyListeners();
  }

  void remove(String id, ComicType type) {
    _removeFromDb(id, type);
    notifyListeners();
  }

  void removeAll() {
    _db.execute("DELETE FROM read_later;");
    notifyListeners();
  }

  bool exists(String id, ComicType type) {
    return _existsInDb(id, type);
  }

  List<ReadLaterItem> getAll() {
    var res = _db.select(
      "SELECT * FROM read_later ORDER BY added_time DESC;",
    );
    return res.map((row) => ReadLaterItem.fromRow(row)).toList();
  }

  void close() {
    isInitialized = false;
    HistoryManager().removeListener(_onHistoryChanged);
    _db.dispose();
    _cache = null;
  }
}
