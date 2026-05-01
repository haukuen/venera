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

void handleLinks() {
  final appLinks = AppLinks();
  appLinks.uriLinkStream.listen((uri) {
    handleAppLink(uri);
  });
}

Future<bool> handleAppLink(Uri uri) async {
  if (uri.scheme == 'venera') {
    String? id;
    String? sourceKey;
    String? title;

    if (uri.host == 'c' && uri.pathSegments.length >= 2) {
      // Short format: venera://c/{source}/{id}
      sourceKey = uri.pathSegments[0];
      id = uri.pathSegments[1];
    } else if (uri.host == 'comic') {
      // Legacy format: venera://comic?id=xxx&source=xxx&title=xxx
      id = uri.queryParameters['id'];
      sourceKey = uri.queryParameters['source'];
      title = uri.queryParameters['title'];
    }

    if (id == null || sourceKey == null) {
      // Not a valid comic link, fall through to other handlers
    } else {
      final comicId = id;
      final comicSource = sourceKey;
      if (App.mainNavigatorKey == null) {
        await Future.delayed(const Duration(milliseconds: 200));
      }

      final source = ComicSource.find(comicSource);
      if (source != null) {
        App.mainNavigatorKey!.currentContext?.to(() {
          return ComicPage(id: comicId, sourceKey: comicSource);
        });
      } else if (title != null && title.isNotEmpty) {
        final keyword = title;
        App.rootContext.showMessage(
          message: 'Comic source not found: @s'.tlParams({'s': comicSource}),
        );
        App.rootContext.to(() => AggregatedSearchPage(keyword: keyword));
      }
      return true;
    }
  }

  for(var source in ComicSource.all()) {
    if(source.linkHandler != null) {
      if(source.linkHandler!.domains.contains(uri.host)) {
        var id = source.linkHandler!.linkToId(uri.toString());
        if(id != null) {
          if(App.mainNavigatorKey == null) {
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