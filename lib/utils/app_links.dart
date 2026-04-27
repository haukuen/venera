import 'package:app_links/app_links.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

void handleLinks() {
  final appLinks = AppLinks();
  appLinks.uriLinkStream.listen((uri) {
    handleAppLink(uri);
  });
}

Future<bool> handleAppLink(Uri uri) async {
  if (uri.scheme == 'venera' && uri.host == 'comic') {
    final id = uri.queryParameters['id'];
    final sourceKey = uri.queryParameters['source'];
    final title = uri.queryParameters['title'];
    if (id == null || sourceKey == null) return false;

    if (App.mainNavigatorKey == null) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    final source = ComicSource.find(sourceKey);
    if (source != null) {
      App.mainNavigatorKey!.currentContext?.to(() {
        return ComicPage(id: id, sourceKey: sourceKey);
      });
    } else if (title != null && title.isNotEmpty) {
      App.rootContext.showMessage(
        message: 'Comic source not found: $sourceKey',
      );
      App.rootContext.to(() => AggregatedSearchPage(keyword: title));
    }
    return true;
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