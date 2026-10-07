part of 'package:venera/pages/home_page.dart';

class _ReadLater extends StatefulWidget {
  const _ReadLater();

  @override
  State<_ReadLater> createState() => _ReadLaterState();
}

class _ReadLaterState extends State<_ReadLater> {
  List<ReadLaterItem> items = [];
  int itemCount = 0;

  void _onDataChanged() {
    if (mounted) {
      setState(() {
        items = ReadLaterManager().getAll();
        itemCount = ReadLaterManager().count;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    items = ReadLaterManager().getAll();
    itemCount = ReadLaterManager().count;
    ReadLaterManager().addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ReadLaterManager().removeListener(_onDataChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }

    return SliverToBoxAdapter(
      child: HomeSectionCard(
        title: 'Read Later'.tl,
        count: itemCount,
        onTap: () {
          context.to(() => const _ReadLaterPage());
        },
        content: ComicHorizontalList(
          comics: items,
          heroTagPrefix: 'readLater_',
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
        ),
      ),
    );
  }
}

class _ReadLaterPage extends StatefulWidget {
  const _ReadLaterPage();

  @override
  State<_ReadLaterPage> createState() => _ReadLaterPageState();
}

class _ReadLaterPageState extends State<_ReadLaterPage> {
  @override
  void initState() {
    ReadLaterManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    ReadLaterManager().removeListener(onUpdate);
    super.dispose();
  }

  var comics = ReadLaterManager().getAll();
  bool multiSelectMode = false;
  Map<ReadLaterItem, bool> selectedComics = {};

  void onUpdate() {
    if (mounted) {
      setState(() {
        comics = ReadLaterManager().getAll();
        selectedComics.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      });
    }
  }

  void selectAll() {
    setState(() {
      selectedComics = {for (var c in comics) c: true};
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      for (var c in comics) {
        selectedComics[c] = !selectedComics.putIfAbsent(c, () => false);
      }
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () {
                final toDelete = List<ReadLaterItem>.from(selectedComics.keys);
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
                for (final comic in toDelete) {
                  ReadLaterManager().remove(comic.id, comic.type);
                }
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear'.tl,
        child: IconButton(
          icon: const Icon(Icons.clear_all),
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) {
                return ContentDialog(
                  title: 'Clear'.tl,
                  content: Text(
                    'Are you sure you want to clear your read later list?'.tl,
                  ),
                  actions: [
                    Button.filled(
                      color: context.colorScheme.error,
                      onPressed: () {
                        ReadLaterManager().removeAll();
                        context.pop();
                      },
                      child: Text('Clear'.tl),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text('Read Later'.tl),
              actions: multiSelectMode ? selectActions : normalActions,
            ),
            if (comics.isEmpty)
              SliverToBoxAdapter(
                child: Center(child: Text('No items'.tl).paddingTop(200)),
              )
            else
              SliverGridComics(
                comics: comics,
                selections: selectedComics,
                onLongPressed: null,
                onTap: multiSelectMode
                    ? (c, heroID) {
                        setState(() {
                          if (selectedComics.containsKey(c as ReadLaterItem)) {
                            selectedComics.remove(c);
                          } else {
                            selectedComics[c] = true;
                          }
                          if (selectedComics.isEmpty) {
                            multiSelectMode = false;
                          }
                        });
                      }
                    : null,
                badgeBuilder: (c) {
                  return ComicSource.find(c.sourceKey)?.name;
                },
                menuBuilder: (c) {
                  return [
                    MenuEntry(
                      icon: Icons.remove,
                      text: 'Remove'.tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        ReadLaterManager().remove(
                          c.id,
                          ComicType(
                            c.sourceKey == 'local' ? 0 : c.sourceKey.hashCode,
                          ),
                        );
                      },
                    ),
                  ];
                },
              ),
          ],
        ),
      ),
    );
  }
}
