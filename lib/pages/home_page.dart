import 'package:flutter/material.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/app_theme.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/comic_archive_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/image_favorites_page/image_favorites_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/comic_backup.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

import 'local_comics_page.dart';

part 'home/search_bar.dart';
part 'home/sync_data.dart';
part 'home/history.dart';
part 'home/local.dart';
part 'home/comic_archive.dart';
part 'home/import_comics.dart';
part 'home/comic_source.dart';
part 'home/image_favorites.dart';
part 'home/read_later.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    var widget = SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        const _SearchBar(),
        const _SyncDataWidget(),
        const _ReadLater(),
        const _History(),
        const _Local(),
        const FollowUpdatesWidget(),
        const _ComicSourceWidget(),
        const ImageFavorites(),
        const _ComicArchiveWidget(),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    return context.width > changePoint ? widget.paddingHorizontal(8) : widget;
  }
}
