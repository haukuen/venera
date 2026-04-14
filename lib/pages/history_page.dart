import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

enum _HistoryGroup { today, yesterday, week, earlier }

extension _HistoryGroupLabel on _HistoryGroup {
  String get label => switch (this) {
    _HistoryGroup.today => 'Today',
    _HistoryGroup.yesterday => 'Yesterday',
    _HistoryGroup.week => 'This Week',
    _HistoryGroup.earlier => 'Earlier',
  };
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    HistoryManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    super.dispose();
  }

  void onUpdate() {
    setState(() {
      comics = HistoryManager().getAll();
      if (multiSelectMode) {
        selectedComics.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  var comics = HistoryManager().getAll();
  var controller = FlyoutController();

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

  bool _isSearchMode = false;
  String _searchQuery = '';

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  void _removeHistory(History comic) {
    if (comic.sourceKey.startsWith("Unknown")) {
      HistoryManager().remove(
        comic.id,
        ComicType(int.parse(comic.sourceKey.split(':')[1])),
      );
    } else if (comic.sourceKey == 'local') {
      HistoryManager().remove(
        comic.id,
        ComicType.local,
      );
    } else {
      HistoryManager().remove(
        comic.id,
        ComicType(comic.sourceKey.hashCode),
      );
    }
  }

  void _refreshHistory(History comic) async {
    var result = await HistoryManager().refreshHistoryInfo(comic);
    if (result) {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Success".tl);
      }
    } else {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Failed".tl);
      }
    }
  }

  void _refreshAllHistories() async {
    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Refreshing Histories".tl,
    );

    int success = 0;
    int failed = 0;
    int skipped = 0;

    await for (var progress
        in HistoryManager().refreshAllHistoriesStream()) {
      if (isCanceled) {
        return;
      }
      if (progress.total > 0) {
        loadingController.setProgress(progress.current / progress.total);
      }
      success = progress.success;
      failed = progress.failed;
      skipped = progress.skipped;
    }

    loadingController.close();

    if (mounted) {
      App.rootContext.showMessage(
        message:
            "Refresh Completed: Success @success, Failed @failed, Skipped @skipped"
                .tlParams({
          'success': success,
          'failed': failed,
          'skipped': skipped,
        }),
      );
    }
  }

  List<History> get _filteredComics {
    if (_searchQuery.isEmpty) return comics;
    final query = _searchQuery.toLowerCase();
    return comics.where((c) => c.title.toLowerCase().contains(query)).toList();
  }

  Map<_HistoryGroup, List<History>> _groupByTime(List<History> comics) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekAgo = today.subtract(const Duration(days: 7));

    final groups = <_HistoryGroup, List<History>>{};
    for (final comic in comics) {
      final comicDate = DateTime(
        comic.time.year,
        comic.time.month,
        comic.time.day,
      );
      final _HistoryGroup group;
      if (!comicDate.isBefore(today)) {
        group = _HistoryGroup.today;
      } else if (!comicDate.isBefore(yesterday)) {
        group = _HistoryGroup.yesterday;
      } else if (!comicDate.isBefore(weekAgo)) {
        group = _HistoryGroup.week;
      } else {
        group = _HistoryGroup.earlier;
      }
      groups.putIfAbsent(group, () => []).add(comic);
    }
    return groups;
  }

  List<Widget> _buildGroupedSlivers(BuildContext context) {
    final filtered = _filteredComics;
    final groups = _groupByTime(filtered);
    final slivers = <Widget>[];

    for (final group in _HistoryGroup.values) {
      final items = groups[group];
      if (items == null || items.isEmpty) continue;

      slivers.add(SliverToBoxAdapter(
        child: Container(
          padding: const EdgeInsets.only(
            left: 16,
            top: 16,
            bottom: 4,
          ),
          child: Text(
            group.label.tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ));

      slivers.add(SliverGridComics(
        comics: items,
        selections: selectedComics,
        onLongPressed: null,
        onTap: multiSelectMode
            ? (c, heroID) {
                setState(() {
                  if (selectedComics.containsKey(c as History)) {
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
              icon: Icons.refresh,
              text: 'Refresh Info'.tl,
              onClick: () {
                _refreshHistory(c as History);
              },
            ),
            MenuEntry(
              icon: Icons.remove,
              text: 'Remove'.tl,
              color: context.colorScheme.error,
              onClick: () {
                _removeHistory(c as History);
              },
            ),
          ];
        },
      ));
    }

    if (filtered.isEmpty) {
      slivers.add(SliverToBoxAdapter(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 64),
          child: Center(
            child: Text(
              _searchQuery.isEmpty ? 'No history'.tl : 'No results'.tl,
              style: ts.withColor(context.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      ));
    }

    return slivers;
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: "Select All".tl,
          onPressed: selectAll
      ),
      IconButton(
          icon: const Icon(Icons.deselect),
          tooltip: "Deselect".tl,
          onPressed: deSelect
      ),
      IconButton(
          icon: const Icon(Icons.flip),
          tooltip: "Invert Selection".tl,
          onPressed: invertSelection
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () {
                final comicsToDelete = List<History>.from(selectedComics.keys);
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });

                for (final comic in comicsToDelete) {
                  _removeHistory(comic);
                }
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.search),
        tooltip: 'Search History'.tl,
        onPressed: () {
          setState(() {
            _isSearchMode = true;
          });
        },
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              content: Text('Are you sure you want to clear your history?'.tl),
              actions: [
                Button.outlined(
                  onPressed: () {
                    HistoryManager().clearUnfavoritedHistory();
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    HistoryManager().clearHistory();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode && !_isSearchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (_isSearchMode) {
          setState(() {
            _isSearchMode = false;
            _searchQuery = '';
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
                  : _isSearchMode
                      ? SizedBox(
                          height: 40,
                          child: TextField(
                            autofocus: true,
                            style: ts.s16,
                            decoration: InputDecoration(
                              hintText: 'Search History'.tl,
                              border: InputBorder.none,
                            ),
                            onChanged: (value) {
                              setState(() {
                                _searchQuery = value;
                              });
                            },
                          ),
                        )
                      : Text('History'.tl),
              actions: multiSelectMode
                  ? selectActions
                  : _isSearchMode
                      ? [
                          IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Cancel'.tl,
                            onPressed: () {
                              setState(() {
                                _isSearchMode = false;
                                _searchQuery = '';
                              });
                            },
                          ),
                        ]
                      : normalActions,
            ),
            ..._buildGroupedSlivers(context),
          ],
        ),
      ),
    );
  }

  String getDescription(History h) {
    var res = "";
    if (h.ep >= 1) {
      res += "Chapter @ep".tlParams({
        "ep": h.ep,
      });
    }
    if (h.page >= 1) {
      if (h.ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({
        "page": h.page,
      });
    }
    return res;
  }
}
