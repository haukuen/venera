part of 'package:venera/pages/home_page.dart';

class _ComicSourceWidget extends StatefulWidget {
  const _ComicSourceWidget();

  @override
  State<_ComicSourceWidget> createState() => _ComicSourceWidgetState();
}

class _ComicSourceWidgetState extends State<_ComicSourceWidget> {
  late List<String> comicSources;

  void onComicSourceChange() {
    setState(() {
      comicSources = ComicSource.all().map((e) => e.name).toList();
    });
  }

  @override
  void initState() {
    comicSources = ComicSource.all().map((e) => e.name).toList();
    ComicSourceManager().addListener(onComicSourceChange);
    super.initState();
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(onComicSourceChange);
    super.dispose();
  }

  int get _availableUpdates {
    int c = 0;
    ComicSourceManager().availableUpdates.forEach((key, version) {
      var source = ComicSource.find(key);
      if (source != null) {
        if (compareSemVer(version, source.version)) {
          c++;
        }
      }
    });
    return c;
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: HomeSectionCard(
        title: 'Comic Source'.tl,
        count: comicSources.length,
        onTap: () {
          context.to(() => const ComicSourcePage());
        },
        content: comicSources.isNotEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      runSpacing: AppSpace.sm,
                      spacing: AppSpace.sm,
                      children: comicSources.map((e) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.sm,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          child: Text(e),
                        );
                      }).toList(),
                    ),
                  ).paddingHorizontal(AppSpace.lg).paddingBottom(AppSpace.lg),
                  if (_availableUpdates > 0)
                    Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.sm,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: context.colorScheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.update,
                                color: context.colorScheme.primary,
                                size: 20,
                              ),
                              const SizedBox(width: AppSpace.sm),
                              Text(
                                "@c updates".tlParams({'c': _availableUpdates}),
                                style: ts.withColor(
                                  context.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        )
                        .toAlign(Alignment.centerLeft)
                        .paddingHorizontal(AppSpace.lg)
                        .paddingBottom(AppSpace.sm),
                ],
              )
            : null,
      ),
    );
  }
}
