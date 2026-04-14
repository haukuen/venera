# History Page Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add time-based grouping (Today/Yesterday/This Week/Earlier) and title search to the history page.

**Architecture:** Refactor `history_page.dart` to group the flat `List<History>` into time buckets before rendering. Each bucket gets a `SliverToBoxAdapter` header + `SliverGridComics`. Add a search mode that filters by title before grouping. All existing functionality (multi-select, delete, refresh, clear) is preserved.

**Tech Stack:** Flutter/Dart, existing `SliverGridComics` and `SliverAppbar` components, `assets/translation.json` for i18n.

---

### Task 1: Add translation keys

**Files:**
- Modify: `assets/translation.json`

- [ ] **Step 1: Add new translation entries for both locales**

Add the following keys to the `"zh_CN"` object (alphabetically near existing entries):

```json
"Earlier": "更早",
"This Week": "本周",
"Today": "今天",
"Yesterday": "昨天"
```

Add the same keys to the `"zh_TW"` object:

```json
"Earlier": "更早",
"This Week": "本週",
"Today": "今天",
"Yesterday": "昨天"
```

Note: `"Search History"` already exists in both locales.

- [ ] **Step 2: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('assets/translation.json')); print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add assets/translation.json
git commit -m "feat: add translation keys for history page grouping"
```

---

### Task 2: Add grouping logic and refactor HistoryPage

**Files:**
- Modify: `lib/pages/history_page.dart`

- [ ] **Step 1: Add grouping method to `_HistoryPageState`**

Add the following method after the `invertSelection` method (around line 66). This converts a flat list into grouped entries:

```dart
enum _HistoryGroup { today, yesterday, week, earlier }

extension _HistoryGroupLabel on _HistoryGroup {
  String get label => switch (this) {
    _HistoryGroup.today => 'Today',
    _HistoryGroup.yesterday => 'Yesterday',
    _HistoryGroup.week => 'This Week',
    _HistoryGroup.earlier => 'Earlier',
  };
}
```

Add this method inside `_HistoryPageState`:

```dart
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
```

- [ ] **Step 2: Add search state fields**

Add these fields to `_HistoryPageState` (after `selectedComics`, around line 45):

```dart
bool _isSearchMode = false;
String _searchQuery = '';
```

Update the `onUpdate` method to also clear selected comics that are no longer in the filtered list. Replace the existing `onUpdate`:

```dart
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
```

(This is the same logic — no change needed to `onUpdate` itself. The filtering happens in the getter below.)

Add a getter for filtered + grouped comics:

```dart
List<History> get _filteredComics {
  if (_searchQuery.isEmpty) return comics;
  final query = _searchQuery.toLowerCase();
  return comics.where((c) => c.title.toLowerCase().contains(query)).toList();
}
```

- [ ] **Step 3: Replace the build method's sliver body**

Replace the `SliverGridComics` widget and everything after the `SliverAppbar` in the `build` method (lines 273-313 inside the `SmoothCustomScrollView` slivers list) with the grouped rendering logic:

Remove the single `SliverGridComics(...)` block (lines 273-313).

Add in its place:

```dart
..._buildGroupedSlivers(context),
```

Add this method to `_HistoryPageState`:

```dart
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
```

- [ ] **Step 4: Add search mode to AppBar**

Modify the `normalActions` list in the `build` method. Add a search icon button as the first item in `normalActions` (before the refresh button):

```dart
IconButton(
  icon: const Icon(Icons.search),
  tooltip: 'Search History'.tl,
  onPressed: () {
    setState(() {
      _isSearchMode = true;
    });
  },
),
```

Modify the `SliverAppbar` in the `build` method. Replace the `title:` parameter logic:

Change:
```dart
title: multiSelectMode
    ? Text(selectedComics.length.toString())
    : Text('History'.tl),
```

To:
```dart
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
```

In search mode, replace `normalActions` with just a close button. Modify the `actions:` assignment:

Change:
```dart
actions: multiSelectMode ? selectActions : normalActions,
```

To:
```dart
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
```

Also update the leading button's back behavior to exit search mode:

In the `SliverAppbar`'s `leading` (which is currently not set in the non-multiSelect case — the default back button handles it). The `PopScope` at the bottom of `build` needs updating too. Change `onPopInvokedWithResult`:

```dart
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
```

And update `canPop`:

```dart
canPop: !multiSelectMode && !_isSearchMode,
```

- [ ] **Step 5: Verify the app builds**

Run: `flutter analyze lib/pages/history_page.dart`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add lib/pages/history_page.dart
git commit -m "feat: add time-based grouping and title search to history page"
```
