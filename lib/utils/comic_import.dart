import 'dart:convert';
import 'dart:isolate';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'comic_export.dart';

/// 导入结果
class ImportResult {
  final int imported;
  final int skipped;
  final List<String> errors;

  ImportResult({
    required this.imported,
    required this.skipped,
    this.errors = const [],
  });
}

/// 漫画导入工具
class ComicImporter {
  /// 从 .venera-comics 文件导入漫画
  static Future<ImportResult> importComics({
    required String filePath,
    void Function(int current, int total)? onProgress,
  }) async {
    // 1. 解压到临时目录
    final tempDirPath = FilePath.join(App.cachePath, 'comic_import_temp');
    final tempDir = Directory(tempDirPath);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    tempDir.createSync();

    try {
      await Isolate.run(() {
        ZipFile.openAndExtract(filePath, tempDirPath);
      });

      // 2. 读取 metadata.json
      final metadataFile = File(FilePath.join(tempDirPath, 'metadata.json'));
      if (!metadataFile.existsSync()) {
        return ImportResult(
          imported: 0,
          skipped: 0,
          errors: ['Invalid file: metadata.json not found'],
        );
      }

      final metadataJson =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final comicsJson = metadataJson['comics'] as List<dynamic>;
      final comicsInfo = comicsJson
          .map((e) => _parseComicExportInfo(e as Map<String, dynamic>))
          .toList();

      // 3. 检查本地重复，过滤已存在的漫画
      final comicsToImport = <ComicExportInfo>[];
      var skippedCount = 0;

      for (var info in comicsInfo) {
        if (_isComicExists(info.id, info.comicType)) {
          skippedCount++;
        } else {
          comicsToImport.add(info);
        }
      }

      // 4. 导入漫画
      final errors = <String>[];
      for (var i = 0; i < comicsToImport.length; i++) {
        try {
          final info = comicsToImport[i];
          await _importSingleComic(info, tempDirPath);
          onProgress?.call(i + 1, comicsToImport.length);
        } catch (e, s) {
          Log.error("ComicImporter", "Failed to import ${comicsToImport[i].title}", s);
          errors.add('Failed to import ${comicsToImport[i].title}: $e');
        }
      }

      return ImportResult(
        imported: comicsToImport.length - errors.length,
        skipped: skippedCount,
        errors: errors,
      );
    } finally {
      // 6. 清理临时目录
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  }

  /// 解析漫画导出信息
  static ComicExportInfo _parseComicExportInfo(Map<String, dynamic> json) {
    return ComicExportInfo(
      id: json['id'] as String,
      title: json['title'] as String,
      subtitle: json['subtitle'] as String,
      tags: (json['tags'] as List<dynamic>).map((e) => e as String).toList(),
      directory: json['directory'] as String,
      chapters: (json['chapters'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String)),
      cover: json['cover'] as String,
      comicType: json['comicType'] as int,
      downloadedChapters: (json['downloadedChapters'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      createdAt: json['createdAt'] as int,
      sourceDirectory: json['sourceDirectory'] as String,
    );
  }

  /// 检查漫画是否已存在
  static bool _isComicExists(String id, int comicType) {
    final existing = LocalManager().find(id, ComicType(comicType));
    return existing != null;
  }

  /// 导入单个漫画
  static Future<void> _importSingleComic(
    ComicExportInfo info,
    String tempDirPath,
  ) async {
    final sourceDir = Directory(FilePath.join(tempDirPath, info.sourceDirectory));
    if (!sourceDir.existsSync()) {
      throw Exception('Comic directory not found: ${info.sourceDirectory}');
    }

    // 1. 复制漫画文件到本地存储
    final localPath = LocalManager().path;

    // 如果目标目录已存在，添加后缀避免冲突
    var finalDirectory = info.directory;
    var counter = 1;
    while (Directory(FilePath.join(localPath, finalDirectory)).existsSync()) {
      finalDirectory = '${info.directory}_$counter';
      counter++;
    }

    await copyDirectoryIsolate(
      sourceDir,
      Directory(FilePath.join(localPath, finalDirectory)),
    );

    // 2. 添加到数据库
    final comic = LocalComic(
      id: info.id,
      title: info.title,
      subtitle: info.subtitle,
      tags: info.tags,
      directory: finalDirectory,
      chapters: ComicChapters(info.chapters),
      cover: info.cover,
      comicType: ComicType(info.comicType),
      downloadedChapters: info.downloadedChapters,
      createdAt: DateTime.fromMillisecondsSinceEpoch(info.createdAt),
    );
    LocalManager().add(comic);
  }
}
