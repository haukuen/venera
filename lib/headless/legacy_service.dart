import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/data_sync.dart';

import 'contract.dart';
import 'execution_context.dart';

/// Compatibility implementation for the three commands that predate the
/// schema-versioned comic-source CLI.
///
/// The service reports the original `[CLI PRINT]` payloads as events. The
/// process adapter decides whether to render those events verbatim or return a
/// single JSON envelope.
class LegacyHeadlessService {
  const LegacyHeadlessService();

  Future<Object?> webdav(bool upload) async {
    _legacy({
      'status': 'running',
      'message': upload
          ? 'Uploading WebDAV data...'
          : 'Downloading WebDAV data...',
    });
    if (upload) {
      await DataSync().uploadData();
    } else {
      await DataSync().downloadData();
    }
    var result = {
      'status': 'success',
      'message': upload ? 'Upload complete.' : 'Download complete.',
    };
    _legacy(result);
    return result;
  }

  Future<Object?> updateScripts() async {
    _legacy({
      'status': 'running',
      'message': 'Checking for comic source script updates...',
    });
    await ComicSourcePage.checkComicSourceUpdate();
    var updates = ComicSourceManager().availableUpdates;
    if (updates.isEmpty) {
      var result = {'status': 'success', 'message': 'No updates found.'};
      _legacy(result);
      return result;
    }

    var total = updates.length;
    var current = 0;
    var errors = 0;
    var updated = 0;
    _legacy({
      'status': 'running',
      'message': 'Updating all comic source scripts...',
      'data': {'total': total, 'current': 0, 'updated': 0, 'errors': 0},
    });
    for (var key in updates.keys) {
      CliExecutionContext.current?.cancellation.throwIfCancelled();
      var source = ComicSource.find(key);
      if (source == null) continue;
      current++;
      var data = {
        'current': current,
        'total': total,
        'source': {
          'key': source.key,
          'name': source.name,
          'version': source.version,
          'url': source.url,
        },
      };
      try {
        await ComicSourcePage.update(source, false);
        updated++;
        _legacy({'status': 'running', 'message': 'Progress', 'data': data});
      } catch (error) {
        errors++;
        _legacy({
          'status': 'running',
          'message': 'ProgressError',
          'data': {...data, 'error': error.toString()},
        });
      }
    }
    var result = {
      'status': 'success',
      'message': 'All scripts updated.',
      'data': {'total': total, 'updated': updated, 'errors': errors},
    };
    _legacy(result);
    return result;
  }

  Future<Object?> updateSubscribed({String? comicId, String? sourceKey}) async {
    _legacy({'status': 'running', 'message': 'Updating subscribed comics...'});
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder == null) {
      return _legacyFailure('Follow updates folder is not configured.');
    }

    if ((comicId == null) != (sourceKey == null)) {
      return _legacyFailure(
        'Missing arguments for --update-comic-by-id-type. Expected: '
        '--update-comic-by-id-type <id> <type>',
      );
    }

    if (comicId != null) {
      var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
      var matches = comics.where(
        (comic) => comic.id == comicId && comic.type.sourceKey == sourceKey,
      );
      if (matches.isEmpty) {
        return _legacyFailure(
          'Subscribed comic "$comicId" with type "$sourceKey" was not found.',
        );
      }
      var comic = matches.first;
      var result = await updateComic(comic, folder);
      var data = <String, dynamic>{
        'current': 1,
        'total': 1,
        'comic': {
          'id': comic.id,
          'name': comic.name,
          'coverUrl': comic.coverPath,
          'author': comic.author,
          'type': comic.type.sourceKey,
          'updateTime': comic.updateTime,
          'tags': comic.tags,
        },
      };
      var message = 'Progress';
      if (result.errorMessage != null) {
        message = 'ProgressError';
        data['error'] = result.errorMessage;
      }
      _legacy({'status': 'running', 'message': message, 'data': data});
      _legacy({
        'status': 'running',
        'message': 'Update check complete.',
        'data': {
          'total': 1,
          'updated': result.updated ? 1 : 0,
          'errors': result.errorMessage != null ? 1 : 0,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      var payload = {
        'status': result.errorMessage != null ? 'error' : 'success',
        'message': 'Updated comics list.',
        'data': jsonDecode(await getUpdatedComicsAsJson(folder)),
      };
      _legacy(payload);
      if (result.errorMessage != null) {
        throw CliFailure.source(
          result.errorMessage!,
          source: sourceKey!,
          operation: 'updatesubscribe',
        );
      }
      return payload;
    }

    var total = 0;
    var updated = 0;
    var errors = 0;
    await for (var progress in updateFolder(folder, true)) {
      CliExecutionContext.current?.cancellation.throwIfCancelled();
      total = progress.total;
      updated = progress.updated;
      errors = progress.errors;
      var data = <String, dynamic>{
        'current': progress.current,
        'total': progress.total,
      };
      if (progress.comic != null) {
        data['comic'] = {
          'id': progress.comic!.id,
          'name': progress.comic!.name,
          'coverUrl': progress.comic!.coverPath,
          'author': progress.comic!.author,
          'type': progress.comic!.type.sourceKey,
          'updateTime': progress.comic!.updateTime,
          'tags': progress.comic!.tags,
        };
      }
      var message = 'Progress';
      if (progress.errorMessage != null) {
        message = 'ProgressError';
        data['error'] = progress.errorMessage;
      }
      _legacy({'status': 'running', 'message': message, 'data': data});
    }
    _legacy({
      'status': 'running',
      'message': 'Update check complete.',
      'data': {'total': total, 'updated': updated, 'errors': errors},
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
    var payload = {
      'status': errors > 0 ? 'error' : 'success',
      'message': 'Updated comics list.',
      'data': jsonDecode(await getUpdatedComicsAsJson(folder)),
    };
    _legacy(payload);
    if (errors > 0) {
      throw CliFailure(
        code: 'legacy_command_failed',
        message: '$errors subscribed comic update(s) failed.',
        exitCode: CliExitCode.sourceError,
        data: payload,
      );
    }
    return payload;
  }

  Never _legacyFailure(String message) {
    _legacy({'status': 'error', 'message': message});
    throw CliFailure(
      code: 'legacy_command_failed',
      message: message,
      exitCode: CliExitCode.sourceError,
    );
  }

  void _legacy(Map<String, dynamic> payload) {
    CliExecutionContext.current?.reporter.legacy(payload);
  }
}
