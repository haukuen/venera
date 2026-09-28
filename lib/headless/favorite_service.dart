import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/cache.dart';

import 'contract.dart';
import 'execution_context.dart';
import 'source_coordinator.dart';
import 'source_service.dart';

enum FavoriteState { favorited, notFavorited, unknown }

enum FolderMembershipState { known, unknown, notApplicable }

class FavoriteStatus {
  final FavoriteState state;
  final FolderMembershipState folderMembership;
  final List<String> folderIds;
  final Map<String, String> folders;
  final List<String> evidence;
  final List<CliWarning> warnings;

  const FavoriteStatus({
    required this.state,
    required this.folderMembership,
    required this.folderIds,
    required this.folders,
    required this.evidence,
    required this.warnings,
  });

  Map<String, dynamic> toJson() => {
    'state': switch (state) {
      FavoriteState.favorited => 'favorited',
      FavoriteState.notFavorited => 'not_favorited',
      FavoriteState.unknown => 'unknown',
    },
    'folderMembership': switch (folderMembership) {
      FolderMembershipState.known => 'known',
      FolderMembershipState.unknown => 'unknown',
      FolderMembershipState.notApplicable => 'not_applicable',
    },
    'folderIds': folderIds,
    'folders': folders,
    'evidence': evidence,
  };
}

class CliFavoriteService {
  final CliSourceService sources;
  final SourceOperationCoordinator coordinator;

  CliFavoriteService({
    this.sources = const CliSourceService(),
    SourceOperationCoordinator? coordinator,
  }) : coordinator = coordinator ?? SourceOperationCoordinator.instance;

  Future<Map<String, dynamic>> listFavorites({
    required String sourceKey,
    String? folderId,
    required CliPaginationRequest pagination,
  }) async {
    var source = sources.requireSource(sourceKey, operation: 'favorite.list');
    var favorite = _requireFavorites(source, 'favorite.list');
    _validateFolderArgument(favorite, folderId);
    return coordinator.query(sourceKey, () async {
      NetworkCacheManager().clear();
      var list = await sources.loadComicList(
        source: source,
        operation: 'favorite.list',
        loadPage: favorite.loadComic == null
            ? null
            : (page) => favorite.loadComic!(page, folderId),
        loadNext: favorite.loadNext == null
            ? null
            : (cursor) => favorite.loadNext!(cursor, folderId),
        request: pagination,
      );
      return {
        'source': {'key': source.key, 'name': source.name},
        'folderId': folderId,
        ...list,
      };
    });
  }

  Future<Map<String, dynamic>> status({
    required String sourceKey,
    required String comicId,
  }) async {
    var source = sources.requireSource(sourceKey, operation: 'favorite.status');
    _requireFavorites(source, 'favorite.status');
    var status = await coordinator.query(sourceKey, () {
      NetworkCacheManager().clear();
      return _inspect(source, comicId);
    });
    for (var warning in status.warnings) {
      CliExecutionContext.current?.reporter.warning(
        warning.code,
        warning.message,
        source: warning.source,
        details: warning.details,
      );
    }
    return {
      'source': {'key': source.key, 'name': source.name},
      'comicId': comicId,
      ...status.toJson(),
    };
  }

  Future<Map<String, dynamic>> add({
    required String sourceKey,
    required String comicId,
    String? folderId,
    String? favoriteId,
    required bool dryRun,
    required int verifyMaxPages,
  }) {
    return _mutate(
      sourceKey: sourceKey,
      comicId: comicId,
      folderId: folderId,
      favoriteId: favoriteId,
      adding: true,
      dryRun: dryRun,
      verifyMaxPages: verifyMaxPages,
    );
  }

  Future<Map<String, dynamic>> remove({
    required String sourceKey,
    required String comicId,
    String? folderId,
    String? favoriteId,
    required bool dryRun,
    required int verifyMaxPages,
  }) {
    return _mutate(
      sourceKey: sourceKey,
      comicId: comicId,
      folderId: folderId,
      favoriteId: favoriteId,
      adding: false,
      dryRun: dryRun,
      verifyMaxPages: verifyMaxPages,
    );
  }

  Future<List<Map<String, dynamic>>> listFolders(String sourceKey) async {
    var source = sources.requireSource(
      sourceKey,
      operation: 'favorite.folder.list',
    );
    var favorite = _requireFavorites(source, 'favorite.folder.list');
    if (!favorite.multiFolder || favorite.loadFolders == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" does not provide remote favorite folders.',
        source: sourceKey,
        operation: 'favorite.folder.list',
      );
    }
    var folders = await coordinator.query(sourceKey, () async {
      NetworkCacheManager().clear();
      return _unwrap(
        await favorite.loadFolders!(),
        sourceKey,
        'favorite.folder.list',
      );
    });
    var result = <Map<String, dynamic>>[
      for (var entry in folders.entries)
        {
          'id': entry.key,
          'name': entry.value,
          'isAllFavorites': entry.key == favorite.allFavoritesId,
          'synthetic': false,
        },
    ];
    if (favorite.allFavoritesId != null &&
        !folders.containsKey(favorite.allFavoritesId)) {
      result.insert(0, {
        'id': favorite.allFavoritesId,
        'name': 'All',
        'isAllFavorites': true,
        'synthetic': true,
      });
    }
    return result;
  }

  Future<Map<String, dynamic>> createFolder({
    required String sourceKey,
    required String name,
    required bool dryRun,
  }) async {
    if (name.trim().isEmpty) {
      throw CliFailure.invalid('Folder name must not be empty.');
    }
    var source = sources.requireSource(
      sourceKey,
      operation: 'favorite.folder.create',
    );
    var favorite = _requireFavorites(source, 'favorite.folder.create');
    if (favorite.addFolder == null || favorite.loadFolders == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" cannot create favorite folders.',
        source: sourceKey,
        operation: 'favorite.folder.create',
      );
    }
    return coordinator.write(sourceKey, () async {
      NetworkCacheManager().clear();
      var before = await _unwrap(
        await favorite.loadFolders!(),
        sourceKey,
        'favorite.folder.create',
      );
      var matches = before.entries
          .where((entry) => entry.value == name)
          .toList();
      if (matches.length > 1) {
        throw CliFailure.conflict(
          'duplicate_folder_name',
          'More than one folder is named "$name".',
          source: sourceKey,
          operation: 'favorite.folder.create',
        );
      }
      if (matches.length == 1) {
        return {
          'changed': false,
          'verification': 'already_satisfied',
          'folder': {'id': matches.single.key, 'name': matches.single.value},
          'dryRun': dryRun,
        };
      }
      if (dryRun) {
        return {
          'changed': false,
          'wouldChange': true,
          'allowed': true,
          'requiredFlags': const <String>[],
          'verification': 'planned',
          'folder': {'id': null, 'name': name},
          'dryRun': true,
        };
      }
      var context = CliExecutionContext.current;
      context?.cancellation.throwIfCancelled();
      Object? writeError;
      try {
        var result = await favorite.addFolder!(name);
        if (!result.success) {
          writeError = result.errorMessage ?? 'Unknown source error.';
        }
      } catch (error) {
        writeError = error;
      }
      NetworkCacheManager().clear();
      Map<String, String>? after;
      Object? verificationError;
      try {
        after = await _unwrap(
          await favorite.loadFolders!(),
          sourceKey,
          'favorite.folder.create.verify',
        );
      } catch (error) {
        verificationError = error;
      }
      if (context?.cancellation.isCancelled == true) {
        context?.reporter.warning(
          'cancellation_after_dispatch',
          'Cancellation was requested after the remote write was sent; verification completed before returning.',
          source: sourceKey,
        );
      }
      var additions = after == null
          ? <MapEntry<String, String>>[]
          : after.entries
                .where(
                  (entry) =>
                      !before.containsKey(entry.key) && entry.value == name,
                )
                .toList();
      if (additions.length != 1) {
        throw _outcomeUnknown(
          sourceKey,
          'favorite.folder.create',
          data: {
            'folderName': name,
            'writeError': writeError?.toString(),
            'verificationError': verificationError?.toString(),
          },
        );
      }
      if (writeError != null) {
        context?.reporter.warning(
          'write_response_error_but_verified',
          'The source reported an error for the write, but the requested remote state was verified.',
          source: sourceKey,
          details: {'writeError': writeError.toString()},
        );
      }
      coordinator.favoriteChanged(
        FavoriteChange(
          source: sourceKey,
          operation: 'folder_create',
          folderId: additions.single.key,
        ),
      );
      return {
        'changed': true,
        'verification': 'verified',
        'folder': {'id': additions.single.key, 'name': additions.single.value},
        'dryRun': false,
      };
    });
  }

  Future<Map<String, dynamic>> deleteFolder({
    required String sourceKey,
    required String folderId,
    required bool yes,
    required bool forceNonEmpty,
    required bool dryRun,
  }) async {
    var source = sources.requireSource(
      sourceKey,
      operation: 'favorite.folder.delete',
    );
    var favorite = _requireFavorites(source, 'favorite.folder.delete');
    if (favorite.deleteFolder == null || favorite.loadFolders == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" cannot delete favorite folders.',
        source: sourceKey,
        operation: 'favorite.folder.delete',
      );
    }
    if (favorite.allFavoritesId != null &&
        folderId == favorite.allFavoritesId) {
      throw CliFailure.conflict(
        'protected_folder',
        'The aggregate all-favorites folder cannot be deleted.',
        source: sourceKey,
        operation: 'favorite.folder.delete',
      );
    }
    return coordinator.write(sourceKey, () async {
      NetworkCacheManager().clear();
      var before = await _unwrap(
        await favorite.loadFolders!(),
        sourceKey,
        'favorite.folder.delete',
      );
      if (!before.containsKey(folderId)) {
        throw CliFailure.notFound(
          'Favorite folder "$folderId" was not found.',
          source: sourceKey,
          operation: 'favorite.folder.delete',
        );
      }
      var contentState = await _folderContentState(source, favorite, folderId);
      var requiredFlags = <String>[];
      if (!yes) requiredFlags.add('--yes');
      if (contentState != 'empty' && !forceNonEmpty) {
        requiredFlags.add('--force-non-empty');
      }
      if (dryRun) {
        return {
          'changed': false,
          'wouldChange': true,
          'allowed': requiredFlags.isEmpty,
          'requiredFlags': requiredFlags,
          'contentState': contentState,
          'folder': {'id': folderId, 'name': before[folderId]},
          'verification': 'planned',
          'dryRun': true,
        };
      }
      if (requiredFlags.isNotEmpty) {
        throw CliFailure.conflict(
          'confirmation_required',
          'Deleting this folder requires ${requiredFlags.join(' and ')}.',
          source: sourceKey,
          operation: 'favorite.folder.delete',
          details: {
            'requiredFlags': requiredFlags,
            'contentState': contentState,
          },
        );
      }
      var context = CliExecutionContext.current;
      context?.cancellation.throwIfCancelled();
      Object? writeError;
      try {
        var result = await favorite.deleteFolder!(folderId);
        if (!result.success) {
          writeError = result.errorMessage ?? 'Unknown source error.';
        }
      } catch (error) {
        writeError = error;
      }
      NetworkCacheManager().clear();
      Map<String, String>? after;
      Object? verificationError;
      try {
        after = await _unwrap(
          await favorite.loadFolders!(),
          sourceKey,
          'favorite.folder.delete.verify',
        );
      } catch (error) {
        verificationError = error;
      }
      if (context?.cancellation.isCancelled == true) {
        context?.reporter.warning(
          'cancellation_after_dispatch',
          'Cancellation was requested after the remote write was sent; verification completed before returning.',
          source: sourceKey,
        );
      }
      if (after == null || after.containsKey(folderId)) {
        throw _outcomeUnknown(
          sourceKey,
          'favorite.folder.delete',
          data: {
            'folderId': folderId,
            'writeError': writeError?.toString(),
            'verificationError': verificationError?.toString(),
          },
        );
      }
      if (writeError != null) {
        context?.reporter.warning(
          'write_response_error_but_verified',
          'The source reported an error for the write, but the requested remote state was verified.',
          source: sourceKey,
          details: {'writeError': writeError.toString()},
        );
      }
      coordinator.favoriteChanged(
        FavoriteChange(
          source: sourceKey,
          operation: 'folder_delete',
          folderId: folderId,
        ),
      );
      return {
        'changed': true,
        'verification': 'verified',
        'folder': {'id': folderId, 'name': before[folderId]},
        'contentState': contentState,
        'dryRun': false,
      };
    });
  }

  Future<Map<String, dynamic>> _mutate({
    required String sourceKey,
    required String comicId,
    required String? folderId,
    required String? favoriteId,
    required bool adding,
    required bool dryRun,
    required int verifyMaxPages,
  }) async {
    if (verifyMaxPages < 1) {
      throw CliFailure.invalid('--verify-max-pages must be at least 1.');
    }
    var operation = adding ? 'favorite.add' : 'favorite.remove';
    var source = sources.requireSource(sourceKey, operation: operation);
    var favorite = _requireFavorites(source, operation);
    if (favorite.addOrDelFavorite == null) {
      throw CliFailure.unsupported(
        'Comic source "$sourceKey" cannot modify remote favorites.',
        source: sourceKey,
        operation: operation,
      );
    }
    _validateFolderArgument(favorite, folderId);
    if (favorite.allFavoritesId != null &&
        folderId == favorite.allFavoritesId) {
      throw CliFailure.conflict(
        'protected_folder',
        'The aggregate all-favorites folder cannot be a mutation target.',
        source: sourceKey,
        operation: operation,
      );
    }
    return coordinator.write(sourceKey, () async {
      NetworkCacheManager().clear();
      var before = await _inspect(source, comicId);
      if (favorite.multiFolder && !before.folders.containsKey(folderId)) {
        throw CliFailure.notFound(
          'Favorite folder "$folderId" was not found.',
          source: sourceKey,
          operation: operation,
        );
      }
      String decision;
      _FolderScan? preflightScan;
      if (favorite.multiFolder &&
          before.folderMembership == FolderMembershipState.unknown) {
        preflightScan = await _scanFolder(
          source,
          favorite,
          folderId!,
          comicId,
          verifyMaxPages,
        );
      }
      if (preflightScan?.found == true) {
        decision = adding ? 'already_satisfied' : 'write';
      } else if (preflightScan?.exhausted == true) {
        if (!adding) {
          decision = 'already_satisfied';
        } else if (favorite.singleFolderForSingleComic &&
            before.state == FavoriteState.favorited) {
          decision =
              'The comic is already in another folder and implicit move is disabled.';
        } else {
          decision = 'write';
        }
      } else {
        decision = adding
            ? _planAdd(favorite, before, folderId)
            : _planRemove(favorite, before, folderId);
      }
      if (decision == 'already_satisfied') {
        return {
          'changed': false,
          'verification': 'already_satisfied',
          'state': before.toJson(),
          'preflightScan': preflightScan?.toJson(),
          'dryRun': dryRun,
        };
      }
      if (decision != 'write') {
        throw CliFailure.conflict(
          'state_unknown',
          decision,
          source: sourceKey,
          operation: operation,
          details: before.toJson(),
        );
      }
      if (dryRun) {
        return {
          'changed': false,
          'wouldChange': true,
          'allowed': true,
          'requiredFlags': const <String>[],
          'verification': 'planned',
          'state': before.toJson(),
          'preflightScan': preflightScan?.toJson(),
          'dryRun': true,
        };
      }
      var context = CliExecutionContext.current;
      context?.cancellation.throwIfCancelled();
      Object? writeError;
      Res<bool>? result;
      try {
        var mutateOnce =
            favorite.addOrDelFavoriteOnce ?? favorite.addOrDelFavorite!;
        result = await mutateOnce(comicId, folderId ?? '', adding, favoriteId);
        if (!result.success) {
          writeError = result.errorMessage ?? 'Unknown source error.';
        }
      } catch (error) {
        writeError = error;
      }
      NetworkCacheManager().clear();
      FavoriteStatus? after;
      bool verified = false;
      Object? verificationError;
      try {
        after = await _inspect(source, comicId);
        verified = await _verifyMutation(
          source: source,
          favorite: favorite,
          comicId: comicId,
          folderId: folderId,
          adding: adding,
          directStatus: after,
          maxPages: verifyMaxPages,
        );
      } catch (error) {
        verificationError = error;
      }
      if (context?.cancellation.isCancelled == true) {
        context?.reporter.warning(
          'cancellation_after_dispatch',
          'Cancellation was requested after the remote write was sent; verification completed before returning.',
          source: sourceKey,
        );
      }
      if (!verified) {
        throw _outcomeUnknown(
          sourceKey,
          operation,
          data: {
            'comicId': comicId,
            'folderId': folderId,
            'requestedState': adding ? 'favorited' : 'not_favorited',
            'observedState': after?.toJson(),
            'writeError': writeError?.toString(),
            'verificationError': verificationError?.toString(),
          },
        );
      }
      if (writeError != null) {
        context?.reporter.warning(
          'write_response_error_but_verified',
          'The source reported an error for the write, but the requested remote state was verified.',
          source: sourceKey,
          details: {'writeError': writeError.toString()},
        );
      }
      coordinator.favoriteChanged(
        FavoriteChange(
          source: sourceKey,
          operation: adding ? 'add' : 'remove',
          comicId: comicId,
          folderId: folderId,
          isFavorited: switch (after!.state) {
            FavoriteState.favorited => true,
            FavoriteState.notFavorited => false,
            FavoriteState.unknown => null,
          },
        ),
      );
      return {
        'changed': true,
        'verification': 'verified',
        'state': after.toJson(),
        'dryRun': false,
      };
    });
  }

  Future<FavoriteStatus> _inspect(ComicSource source, String comicId) async {
    var favorite = _requireFavorites(source, 'favorite.status');
    Map<String, String> folders = {};
    List<String>? folderIds;
    bool? detailsFavorite;
    var evidence = <String>[];
    var warnings = <CliWarning>[];

    if (favorite.multiFolder && favorite.loadFolders != null) {
      var result = await favorite.loadFolders!(comicId);
      folders = await _unwrap(result, source.key, 'favorite.status.folders');
      if (result.subData is List) {
        folderIds = List<String>.from(result.subData as List);
        evidence.add('folders');
      }
    }
    if (source.loadComicInfo != null) {
      var result = await source.loadComicInfo!(comicId);
      var details = await _unwrap(
        result,
        source.key,
        'favorite.status.details',
      );
      detailsFavorite = details.isFavorite;
      if (detailsFavorite != null) evidence.add('details');
    }

    if (!favorite.multiFolder) {
      return FavoriteStatus(
        state: detailsFavorite == true
            ? FavoriteState.favorited
            : detailsFavorite == false
            ? FavoriteState.notFavorited
            : FavoriteState.unknown,
        folderMembership: FolderMembershipState.notApplicable,
        folderIds: const [],
        folders: const {},
        evidence: evidence,
        warnings: warnings,
      );
    }

    var nonEmptyFolders = folderIds?.isNotEmpty == true;
    if (nonEmptyFolders && detailsFavorite == false) {
      warnings.add(
        CliWarning(
          code: 'favorite_state_conflict',
          message:
              'Folder membership reports the comic as favorited while comic details report false.',
          source: source.key,
        ),
      );
    }
    if (detailsFavorite == true && folderIds?.isEmpty == true) {
      warnings.add(
        CliWarning(
          code: 'favorite_membership_unavailable',
          message:
              'The comic is favorited, but the source did not report its folder membership.',
          source: source.key,
        ),
      );
    }

    FavoriteState state;
    FolderMembershipState membership;
    if (nonEmptyFolders) {
      state = FavoriteState.favorited;
      membership = FolderMembershipState.known;
    } else if (detailsFavorite == true) {
      state = FavoriteState.favorited;
      membership = FolderMembershipState.unknown;
    } else if (detailsFavorite == false && folderIds != null) {
      state = FavoriteState.notFavorited;
      membership = FolderMembershipState.known;
    } else if (detailsFavorite == false) {
      state = FavoriteState.notFavorited;
      membership = FolderMembershipState.unknown;
    } else {
      state = FavoriteState.unknown;
      membership = FolderMembershipState.unknown;
    }
    return FavoriteStatus(
      state: state,
      folderMembership: membership,
      folderIds: folderIds ?? const [],
      folders: folders,
      evidence: evidence,
      warnings: warnings,
    );
  }

  String _planAdd(
    FavoriteData favorite,
    FavoriteStatus status,
    String? folderId,
  ) {
    if (!favorite.multiFolder) {
      return switch (status.state) {
        FavoriteState.favorited => 'already_satisfied',
        FavoriteState.notFavorited => 'write',
        FavoriteState.unknown =>
          'The current favorite state is unknown; refusing a possibly toggling write.',
      };
    }
    if (status.folderMembership == FolderMembershipState.known) {
      if (status.folderIds.contains(folderId)) return 'already_satisfied';
      if (favorite.singleFolderForSingleComic && status.folderIds.isNotEmpty) {
        return 'The comic is already in another folder and implicit move is disabled.';
      }
      if (status.state == FavoriteState.notFavorited ||
          !favorite.singleFolderForSingleComic) {
        return 'write';
      }
    }
    if (status.state == FavoriteState.notFavorited) return 'write';
    return 'The comic is favorited but its folder membership is unknown.';
  }

  String _planRemove(
    FavoriteData favorite,
    FavoriteStatus status,
    String? folderId,
  ) {
    if (!favorite.multiFolder) {
      return switch (status.state) {
        FavoriteState.favorited => 'write',
        FavoriteState.notFavorited => 'already_satisfied',
        FavoriteState.unknown =>
          'The current favorite state is unknown; refusing a possibly toggling write.',
      };
    }
    if (status.state == FavoriteState.notFavorited) return 'already_satisfied';
    if (status.folderMembership == FolderMembershipState.known) {
      return status.folderIds.contains(folderId)
          ? 'write'
          : 'already_satisfied';
    }
    return 'The comic is favorited but its folder membership is unknown.';
  }

  Future<bool> _verifyMutation({
    required ComicSource source,
    required FavoriteData favorite,
    required String comicId,
    required String? folderId,
    required bool adding,
    required FavoriteStatus directStatus,
    required int maxPages,
  }) async {
    if (!favorite.multiFolder) {
      return adding
          ? directStatus.state == FavoriteState.favorited
          : directStatus.state == FavoriteState.notFavorited;
    }
    if (directStatus.folderMembership == FolderMembershipState.known) {
      var contains = directStatus.folderIds.contains(folderId);
      return adding ? contains : !contains;
    }
    if (!adding && directStatus.state == FavoriteState.notFavorited) {
      return true;
    }
    var scan = await _scanFolder(
      source,
      favorite,
      folderId!,
      comicId,
      maxPages,
    );
    if (adding) return scan.found;
    return !scan.found && scan.exhausted;
  }

  Future<_FolderScan> _scanFolder(
    ComicSource source,
    FavoriteData favorite,
    String folderId,
    String comicId,
    int maxPages,
  ) async {
    NetworkCacheManager().clear();
    if (favorite.loadComic != null) {
      for (var page = 1; page <= maxPages; page++) {
        var result = await favorite.loadComic!(page, folderId);
        var comics = await _unwrap(result, source.key, 'favorite.verify');
        if (comics.any((comic) => comic.id == comicId)) {
          return _FolderScan(found: true, exhausted: false, pages: page);
        }
        var maxPage = result.subData is num
            ? (result.subData as num).toInt()
            : null;
        if (comics.isEmpty || maxPage != null && page >= maxPage) {
          return _FolderScan(found: false, exhausted: true, pages: page);
        }
      }
      return _FolderScan(found: false, exhausted: false, pages: maxPages);
    }
    if (favorite.loadNext != null) {
      String? cursor;
      for (var page = 1; page <= maxPages; page++) {
        var result = await favorite.loadNext!(cursor, folderId);
        var comics = await _unwrap(result, source.key, 'favorite.verify');
        if (comics.any((comic) => comic.id == comicId)) {
          return _FolderScan(found: true, exhausted: false, pages: page);
        }
        cursor = result.subData?.toString();
        if (comics.isEmpty || cursor == null || cursor.isEmpty) {
          return _FolderScan(found: false, exhausted: true, pages: page);
        }
      }
      return _FolderScan(found: false, exhausted: false, pages: maxPages);
    }
    return const _FolderScan(found: false, exhausted: false, pages: 0);
  }

  Future<String> _folderContentState(
    ComicSource source,
    FavoriteData favorite,
    String folderId,
  ) async {
    try {
      if (favorite.loadComic != null) {
        var result = await favorite.loadComic!(1, folderId);
        var comics = await _unwrap(
          result,
          source.key,
          'favorite.folder.delete.preflight',
        );
        if (comics.isNotEmpty) return 'non_empty';
        var maxPage = result.subData is num
            ? (result.subData as num).toInt()
            : null;
        return maxPage == null || maxPage <= 1 ? 'empty' : 'unknown';
      }
      if (favorite.loadNext != null) {
        var result = await favorite.loadNext!(null, folderId);
        var comics = await _unwrap(
          result,
          source.key,
          'favorite.folder.delete.preflight',
        );
        if (comics.isNotEmpty) return 'non_empty';
        var next = result.subData?.toString();
        return next == null || next.isEmpty ? 'empty' : 'unknown';
      }
    } catch (_) {
      return 'unknown';
    }
    return 'unknown';
  }

  static FavoriteData _requireFavorites(ComicSource source, String operation) {
    var favorite = source.favoriteData;
    if (favorite == null) {
      throw CliFailure.unsupported(
        'Comic source "${source.key}" does not provide remote favorites.',
        source: source.key,
        operation: operation,
      );
    }
    return favorite;
  }

  static void _validateFolderArgument(FavoriteData favorite, String? folderId) {
    if (favorite.multiFolder && (folderId == null || folderId.isEmpty)) {
      throw CliFailure.invalid('--folder is required for this comic source.');
    }
    if (!favorite.multiFolder && folderId != null) {
      throw CliFailure.invalid(
        '--folder is not supported by this single-folder comic source.',
      );
    }
  }

  static Future<T> _unwrap<T>(
    Res<T> result,
    String source,
    String operation,
  ) async {
    if (result.success) return result.data;
    _throwIfError(result, source, operation);
    throw StateError('unreachable');
  }

  static void _throwIfError(Res result, String source, String operation) {
    if (result.success) return;
    var message = result.errorMessage ?? 'Unknown source error.';
    if (message.contains('interactive_required:')) {
      var interactiveMessage = message
          .split('interactive_required:')
          .last
          .trim()
          .split('\n')
          .first;
      throw CliFailure.interactiveRequired(interactiveMessage, source: source);
    }
    if (message == 'Not login' || message.contains('Login expired')) {
      throw CliFailure(
        code: 'login_required',
        message: message,
        exitCode: CliExitCode.authentication,
        source: source,
        operation: operation,
      );
    }
    throw CliFailure.source(message, source: source, operation: operation);
  }

  static CliFailure _outcomeUnknown(
    String source,
    String operation, {
    Object? data,
  }) {
    return CliFailure(
      code: 'outcome_unknown',
      message:
          'The remote write was sent, but the requested final state could not be verified.',
      exitCode: CliExitCode.sourceError,
      retryable: false,
      source: source,
      operation: operation,
      data: data,
    );
  }
}

class _FolderScan {
  final bool found;
  final bool exhausted;
  final int pages;

  const _FolderScan({
    required this.found,
    required this.exhausted,
    required this.pages,
  });

  Map<String, dynamic> toJson() => {
    'found': found,
    'exhausted': exhausted,
    'pages': pages,
  };
}
