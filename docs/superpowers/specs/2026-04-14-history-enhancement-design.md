# History Page Enhancement Design

## Overview

Enhance the history page (`lib/pages/history_page.dart`) with time-based grouping and title search, keeping all existing functionality (multi-select, delete, refresh, clear) intact.

## Changes

### 1. Time-based Grouping

Group `List<History>` into four categories before rendering:

| Group | Condition | Display Key |
|-------|-----------|-------------|
| Today | Same calendar day as now | `"Today"` |
| Yesterday | Previous calendar day | `"Yesterday"` |
| This Week | Within last 7 days but not today/yesterday | `"This Week"` |
| Earlier | More than 7 days ago | `"Earlier"` |

**Rendering:** Replace the single `SliverGridComics` with a loop over groups. Each group renders:
1. `SliverToBoxAdapter` with a header container (left-aligned, `onSurfaceVariant` color, `fontSize: 14`, `fontWeight: w600`, 8px vertical padding)
2. `SliverGridComics` for that group's comics (reuse existing component)

Empty groups are skipped entirely.

### 2. Title Search

**Trigger:** New search icon button (`Icons.search`) in AppBar `normalActions`.

**Behavior:** Tap toggles `_isSearchMode`. In search mode:
- AppBar title becomes a `TextField` with hint "Search History"
- `_searchQuery` filters comics by case-insensitive title match before grouping
- Existing action buttons (multi-select, clear, refresh) are hidden
- A close button exits search mode and clears the query

**Filtering:** On every query change, re-filter `HistoryManager().getAll()` then regroup. No database query needed — all filtering is in-memory on the existing list.

### 3. Translations

Add to `assets/translation.json`:
- `"Today"`, `"Yesterday"`, `"This Week"`, `"Earlier"`, `"Search History"`

Translations follow the existing `.tl` extension pattern.

## Files Changed

| File | Change |
|------|--------|
| `lib/pages/history_page.dart` | Add `_isSearchMode`, `_searchQuery`, grouping method, rebuild sliver list |
| `assets/translation.json` | Add new translation keys |

## Unchanged

- `HistoryManager` — no data layer changes
- `SliverGridComics` — reused as-is for each group
- Multi-select, delete, refresh info, refresh all, clear history — all preserved
- `badgeBuilder` and `menuBuilder` on comic tiles — preserved
