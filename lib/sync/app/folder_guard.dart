/// Safety guard for favorite folder names.
///
/// The favorites business schema stores one SQLite table per folder, so a
/// folder name is a *SQLite identifier*. The sync protocol carries folder
/// names as untrusted remote segments (`favoriteFolder` / `favoriteComic` /
/// `favoriteLink` keys), which means a malicious or buggy peer could otherwise
/// inject SQL through a crafted name (e.g. `x"; DROP TABLE "a"; --`).
///
/// Rule: a folder name is only used as an identifier after [isValidFolderName]
/// passes, and the identifier is always quoted with [quote] / [safeIdentifier]
/// (`"` is doubled). Names that fail validation are skipped by the adapter with
/// a warning; they are never interpolated into SQL.
///
/// This file is deliberately pure Dart (`dart:core` only) so it can be reused
/// by any adapter and exercised from `flutter test`.
library;

/// Default maximum folder name length, measured in Unicode code points.
const int maxFolderNameLength = 80;

/// Reserved names owned by the favorites sync schema.
///
/// A folder with one of these names cannot be created locally (the table
/// already exists) and must never be treated as a folder table.
const Set<String> reservedFolderNames = <String>{'folder_order', 'folder_sync'};

/// Unicode letters / numbers / marks plus ASCII space, `.`, `_` and `-`.
///
/// Everything else (quotes, slashes, backslashes, control characters,
/// separators, punctuation such as `;` or `(`, emoji, ...) is rejected. The
/// allowlist is intentionally strict: the app only needs human folder names,
/// and the handful of characters below are safe inside a quoted identifier.
final RegExp _allowedFolderNamePattern = RegExp(
  r'^[\p{L}\p{N}\p{M} _.\-]+$',
  unicode: true,
);

/// Whether [name] is safe to use as a favorite folder name / table identifier.
bool isValidFolderName(String name) => FolderGuard.isValidFolderName(name);

/// Quotes [identifier] as a SQLite identifier, doubling embedded `"`s.
///
/// This is a pure escaping helper: it does not validate the identifier. Use
/// [safeIdentifier] (or [assertSafe] first) for untrusted names.
String quote(String identifier) => FolderGuard.quote(identifier);

/// Alias of [quote] with an explicit name for call sites that quote arbitrary
/// identifiers.
String quoteIdentifier(String identifier) => quote(identifier);

/// Throws [ArgumentError] unless [name] is a valid folder name.
void assertSafe(String name) => FolderGuard.assertSafe(name);

/// Validates [name] with [isValidFolderName] and returns it quoted.
///
/// Throws [ArgumentError] for invalid names, so an unvalidated remote folder
/// name can never reach SQL: the failure happens before any statement runs.
String safeIdentifier(String name) => FolderGuard.safeIdentifier(name);

/// Namespace-style access to the guard for callers that prefer a class.
abstract final class FolderGuard {
  /// Maximum folder name length in code points.
  static const int maxLength = maxFolderNameLength;

  /// Whether [name] is a valid favorite folder name.
  ///
  /// Requirements:
  ///  * 1..[maxLength] Unicode code points;
  ///  * no control characters (C0, DEL, C1), NUL included;
  ///  * no `/`, `\` or `"` (path / quoting hazards);
  ///  * no leading or trailing whitespace;
  ///  * only Unicode letters, numbers, combining marks, ASCII space, `.`, `_`
  ///    and `-`;
  ///  * not a reserved schema table name ([reservedFolderNames]) and not a
  ///    `sqlite_` internal name.
  static bool isValidFolderName(String name) {
    if (name.isEmpty) return false;
    final codePoints = name.runes.toList(growable: false);
    if (codePoints.length > maxLength) return false;
    for (final codePoint in codePoints) {
      // C0 controls, DEL and NUL.
      if (codePoint < 0x20 || codePoint == 0x7F) return false;
      // C1 controls.
      if (codePoint >= 0x80 && codePoint <= 0x9F) return false;
      // Path separators and the SQL identifier quote character.
      if (codePoint == 0x2F || codePoint == 0x5C || codePoint == 0x22) {
        return false;
      }
    }
    // Reject leading / trailing whitespace (including unicode whitespace).
    if (name.trim() != name) return false;
    final lower = name.toLowerCase();
    if (reservedFolderNames.contains(lower)) return false;
    if (lower.startsWith('sqlite_')) return false;
    return _allowedFolderNamePattern.hasMatch(name);
  }

  /// Quotes [identifier] as a SQLite identifier, doubling embedded `"`s.
  static String quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';

  /// Throws [ArgumentError] unless [name] is a valid folder name.
  static void assertSafe(String name) {
    if (!isValidFolderName(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Unsafe favorite folder name: it could not be used as a SQL identifier',
      );
    }
  }

  /// Validates [name] and returns it quoted as a SQLite identifier.
  static String safeIdentifier(String name) {
    assertSafe(name);
    return quote(name);
  }
}
