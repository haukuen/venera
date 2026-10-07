part of 'package:venera/pages/home_page.dart';

class _History extends StatefulWidget {
  const _History();

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  late List<History> history;
  late int count;

  void onHistoryChange() {
    if (mounted) {
      setState(() {
        history = HistoryManager().getRecent();
        count = HistoryManager().count();
      });
    }
  }

  @override
  void initState() {
    history = HistoryManager().getRecent();
    count = HistoryManager().count();
    HistoryManager().addListener(onHistoryChange);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onHistoryChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: HomeSectionCard(
        title: 'History'.tl,
        count: count,
        onTap: () {
          context.to(() => const HistoryPage());
        },
        content: history.isNotEmpty
            ? ComicHorizontalList(
                comics: history,
                heroTagPrefix: 'history_',
                onItemTap: (comic, heroID) {
                  context.to(
                    () => ComicPage(
                      id: comic.id,
                      sourceKey: comic.sourceKey,
                      cover: comic.cover,
                      title: comic.title,
                      heroID: heroID,
                    ),
                  );
                },
              )
            : null,
      ),
    );
  }
}
