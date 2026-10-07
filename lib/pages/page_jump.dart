import 'package:flutter/widgets.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/log.dart';

import 'category_comics_page.dart';
import 'search_result_page.dart';

/// UI 层负责把 [PageJumpTarget] 落到具体页面，
/// 保持 foundation 模型不依赖 pages。
extension PageJumpTargetJump on PageJumpTarget {
  void jump(BuildContext context) {
    if (page == "search") {
      context.to(
        () => SearchResultPage(
          text: attributes?["text"] ?? attributes?["keyword"] ?? "",
          sourceKey: sourceKey,
          options: List.from(attributes?["options"] ?? []),
        ),
      );
    } else if (page == "category") {
      var key = ComicSource.find(sourceKey)!.categoryData!.key;
      context.to(
        () => CategoryComicsPage(
          categoryKey: key,
          category:
              attributes?["category"] ??
              (throw ArgumentError("Category name is required")),
          options: List.from(attributes?["options"] ?? []),
          param: attributes?["param"],
        ),
      );
    } else {
      Log.error("Page Jump", "Unknown page: $page");
    }
  }
}
