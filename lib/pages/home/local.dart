part of 'package:venera/pages/home_page.dart';

class _Local extends StatefulWidget {
  const _Local();

  @override
  State<_Local> createState() => _LocalState();
}

class _LocalState extends State<_Local> {
  late List<LocalComic> local;
  late int count;

  void onLocalComicsChange() {
    setState(() {
      local = LocalManager().getRecent();
      count = LocalManager().count;
    });
  }

  @override
  void initState() {
    local = LocalManager().getRecent();
    count = LocalManager().count;
    LocalManager().addListener(onLocalComicsChange);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(onLocalComicsChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: HomeSectionCard(
        title: 'Local'.tl,
        count: count,
        onTap: () {
          context.to(() => const LocalComicsPage());
        },
        content: local.isNotEmpty
            ? ComicHorizontalList(
                comics: local,
                heroTagPrefix: 'local_',
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
        actions: Row(
          children: [
            if (LocalManager().downloadingTasks.isNotEmpty)
              Button.outlined(
                child: Row(
                  children: [
                    if (LocalManager().downloadingTasks.first.isPaused)
                      const Icon(Icons.pause_circle_outline, size: 18)
                    else
                      const _AnimatedDownloadingIcon(),
                    const SizedBox(width: 8),
                    Text(
                      "@a Tasks".tlParams({
                        'a': LocalManager().downloadingTasks.length,
                      }),
                    ),
                  ],
                ),
                onPressed: () {
                  showPopUpWidget(context, const DownloadingPage());
                },
              ),
            const Spacer(),
            Button.filled(onPressed: import, child: Text("Import".tl)),
          ],
        ).paddingHorizontal(AppSpace.lg).paddingVertical(AppSpace.sm),
      ),
    );
  }

  void import() {
    showDialog(
      barrierDismissible: false,
      context: App.rootContext,
      builder: (context) {
        return const _ImportComicsWidget();
      },
    );
  }
}

class _AnimatedDownloadingIcon extends StatefulWidget {
  const _AnimatedDownloadingIcon();

  @override
  State<_AnimatedDownloadingIcon> createState() =>
      __AnimatedDownloadingIconState();
}

class __AnimatedDownloadingIconState extends State<_AnimatedDownloadingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      lowerBound: -1,
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Transform.translate(
            offset: Offset(0, 18 * _controller.value),
            child: Icon(
              Icons.arrow_downward,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        );
      },
    );
  }
}
