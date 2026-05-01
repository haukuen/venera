import 'package:app_links/app_links.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

final _veneraLinkRegex = RegExp(r'venera://\S+');

/// Try to parse a venera://comic link from [text].
/// Returns the parsed Uri if found, otherwise null.
Uri? parseVeneraLink(String text) {
  final match = _veneraLinkRegex.firstMatch(text);
  if (match == null) return null;
  return Uri.tryParse(match.group(0)!);
}

/// Parse comic id, sourceKey, and optional title from a venera:// URI.
/// Returns null if the URI is not a valid comic link.
({String id, String sourceKey, String? title})? parseComicFromUri(Uri uri) {
  if (uri.scheme != 'venera') return null;
  if (uri.host == 'c' && uri.pathSegments.length >= 2) {
    return (
      id: uri.pathSegments[1],
      sourceKey: uri.pathSegments[0],
      title: null,
    );
  } else if (uri.host == 'comic') {
    final id = uri.queryParameters['id'];
    final sourceKey = uri.queryParameters['source'];
    if (id == null || sourceKey == null) return null;
    return (id: id, sourceKey: sourceKey, title: uri.queryParameters['title']);
  }
  return null;
}

void handleLinks() {
  final appLinks = AppLinks();
  appLinks.uriLinkStream.listen((uri) {
    handleAppLink(uri);
  });
}

Future<bool> handleAppLink(Uri uri) async {
  if (uri.scheme == 'venera') {
    final comic = parseComicFromUri(uri);
    if (comic != null) {
      final comicId = comic.id;
      final comicSource = comic.sourceKey;
      if (App.mainNavigatorKey == null) {
        await Future.delayed(const Duration(milliseconds: 200));
      }

      final source = ComicSource.find(comicSource);
      if (source != null) {
        App.mainNavigatorKey!.currentContext?.to(() {
          return ComicPage(id: comicId, sourceKey: comicSource);
        });
      } else if (comic.title != null && comic.title!.isNotEmpty) {
        final keyword = comic.title!;
        App.rootContext.showMessage(
          message: 'Comic source not found: @s'.tlParams({'s': comicSource}),
        );
        App.rootContext.to(() => AggregatedSearchPage(keyword: keyword));
      }
      return true;
    }
  }

  for (var source in ComicSource.all()) {
    if (source.linkHandler != null) {
      if (source.linkHandler!.domains.contains(uri.host)) {
        var id = source.linkHandler!.linkToId(uri.toString());
        if (id != null) {
          if (App.mainNavigatorKey == null) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          App.mainNavigatorKey!.currentContext?.to(() {
            return ComicPage(id: id, sourceKey: source.key);
          });
          return true;
        }
        return false;
      }
    }
  }
  return false;
}
