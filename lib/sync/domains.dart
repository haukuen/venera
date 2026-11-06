/// Venera v2 sync data model: domains, field groups, merge rules, key
/// factories and device-local settings.
///
/// This library is deliberately pure Dart (no Flutter, no app/business
/// imports) so the merge engine, the SQLite store and tests can share one
/// definition of the model. It mirrors `doc/webdav_sync_v2_protocol.md`
/// (v0.3):
///
///  * §3   domain / field-group / merge-semantics table
///  * §3.1 LWW-Element-Set plus the per-domain clear cutoff
///  * §3.2 settings that stay device-local and never enter the wire protocol
///  * §3.4 the `auth` (cookie) domain, enabled by default
///  * §3.5 tombstones: deleting a history record must cover both field groups
///  * §3.6 folder visibility cascade for `favoriteComic` membership
///  * D14  wire keys are compact JSON arrays; segments are opaque strings and
///         must never be joined/split by a separator
library;

import 'key_codec.dart';

/// Identifiers of the synced data domains (the `d` field on the wire).
///
/// Wire keys are always a JSON array produced by [SyncKeys] (see §3 and D14).
abstract final class SyncDomains {
  /// Reading history. Key `[comicId, comicType]` (§3).
  ///
  /// The record is split into two independent LWW registers:
  /// [SyncFields.progress] (`ep`, `page`, `readEpisode`, `max_page`,
  /// `chapter_group`, `time`) and [SyncFields.meta] (`title`, `subtitle`,
  /// `cover`). A delete or a domain clear must cover both groups (§3.5).
  static const String history = 'history';

  /// Favorite folders. Key `[folderName]` (§3).
  ///
  /// Mixed domain:
  ///  * folder membership is a set element with add/remove versions; the
  ///    folder is visible while its add version wins over its delete version
  ///    (§3.6), and
  ///  * [SyncFields.meta] stores the folder name / sort value as a LWW
  ///    register.
  ///
  /// Deleting a folder also writes remove versions for every member at the
  /// same version (§3.6 cascade).
  static const String favoriteFolder = 'favoriteFolder';

  /// Folder ordering. Single-value record holding the whole order array as
  /// one LWW register (§3): there is no membership set here, the win is on
  /// the entire array.
  ///
  /// The protocol only says the key is a single value ("单值"), it does not
  /// pin the concrete segment; callers must use a single constant key.
  static const String favoriteOrder = 'favoriteOrder';

  /// Network source binding of a favorite folder. Key `[folderName]`, value
  /// carries `sourceKey` / `folderId`; LWW register (§3).
  static const String favoriteLink = 'favoriteLink';

  /// Comic inside a favorite folder. Key
  /// `[folderName, comicId, comicType]` (§3).
  ///
  /// Mixed domain:
  ///  * membership is an LWW-Element-Set `add`/`del` on the empty field group,
  ///  * [SyncFields.meta] (`name`, `cover`, `author`, `tags`) is a register.
  ///
  /// Membership is only visible when the member add version wins *and* the
  /// owning folder is visible (§3.6).
  static const String favoriteComic = 'favoriteComic';

  /// Read-later list. Key `[comicId, comicType]`; membership only,
  /// LWW-Element-Set (`add` / `del`) (§3).
  static const String readLater = 'readLater';

  /// Image favorites. Key `[comicKey, ep, page]` (§3).
  ///
  /// Page records are set elements (LWW-Element-Set); comic/chapter level
  /// titles are registers. A page's visibility is additionally constrained by
  /// its comic/chapter ancestors when those are deleted (§3.6).
  static const String imageFavorite = 'imageFavorite';

  /// Global settings. Key `[settingKey]`, one LWW register per key (§3).
  ///
  /// Device-local keys never enter the protocol, see [SyncSettingKeys].
  static const String setting = 'setting';

  /// Per-comic settings. Key `[comicKey, settingKey]`; LWW register (§3).
  static const String comicSetting = 'comicSetting';

  /// Comic source definition. Key `[sourceKey]`; LWW register whose payload
  /// references an immutable content-addressed blob (`sha256`), tombstoned on
  /// delete (§3, §6.3).
  static const String comicSource = 'comicSource';

  /// Cookie / login state. Key `[cookieDomain, cookiePath, cookieName]`; one
  /// LWW register per cookie, delete = tombstone (§3.4).
  ///
  /// Enabled by default, see [authEnabledByDefault].
  static const String auth = 'auth';

  /// Every domain of protocol v2, in §2 declaration order.
  static const Set<String> all = <String>{
    history,
    favoriteFolder,
    favoriteOrder,
    favoriteLink,
    favoriteComic,
    readLater,
    imageFavorite,
    setting,
    comicSetting,
    comicSource,
    auth,
  };

  /// Domains enabled without consulting the device-local settings: [all]
  /// minus [auth].
  ///
  /// `auth` is default-on at the product level (§3.4), but it depends on the
  /// device-local "sync login state" toggle ([SyncSettingKeys.syncAuthEnabled])
  /// which must be resolved per device instead of being assumed. Use
  /// [enabledDomains] / [resolveAuthDomainEnabled] for the effective set.
  static const Set<String> defaultEnabled = <String>{
    history,
    favoriteFolder,
    favoriteOrder,
    favoriteLink,
    favoriteComic,
    readLater,
    imageFavorite,
    setting,
    comicSetting,
    comicSource,
  };

  /// Domains that mix set-membership ops and register field groups: the empty
  /// field group carries membership (`add`/`del`), named field groups (e.g.
  /// [SyncFields.meta]) are LWW registers.
  static const Set<String> mixedDomains = <String>{
    favoriteFolder,
    favoriteComic,
    imageFavorite,
  };

  /// Whether [domain] is one of the fixed v2 domain identifiers.
  ///
  /// Unknown domains must be ignored by the engine (§6.1); this helper is for
  /// validating local data and test fixtures.
  static bool isValidDomain(String domain) => all.contains(domain);

  /// Whether [domain] is the login-state domain (§3.4).
  static bool isAuthDomain(String domain) => domain == auth;

  /// Whether [domain] is enabled without asking the device-local settings.
  static bool isDefaultEnabled(String domain) =>
      defaultEnabled.contains(domain);

  /// Whether [domain] mixes set membership and register field groups.
  static bool isMixedDomain(String domain) => mixedDomains.contains(domain);

  /// Whether [domain]'s membership rule is LWW-Element-Set (§3.1).
  static bool isSetDomain(String domain) =>
      mergeRuleFor(domain) == MergeRule.setLwwElement;

  /// Merge rule for the domain's record identity / membership, i.e. ops with
  /// an empty field group [SyncFields.empty].
  ///
  /// Throws [ArgumentError] for unknown domains: the engine has to ignore
  /// unknown domains before dispatching (§6.1) instead of guessing a rule.
  static MergeRule mergeRuleFor(String domain) {
    final rule = _membershipRules[domain];
    if (rule == null) {
      throw ArgumentError.value(domain, 'domain', 'Unknown sync domain');
    }
    return rule;
  }

  /// Merge rule for one field group of [domain].
  ///
  /// Only the empty field group carries membership (`add`/`del`, LWW-Element-
  /// Set). Every named field group — `history.progress`, `history.meta`,
  /// `favoriteFolder.meta`, `favoriteComic.meta`, `imageFavorite` metadata
  /// fields — is a LWW register (§3). Unknown named groups are treated as
  /// registers so newer schema versions stay forward compatible.
  static MergeRule ruleForField(String domain, String field) {
    final membershipRule = mergeRuleFor(domain); // validates domain
    if (field.isEmpty) return membershipRule;
    return MergeRule.registerLww;
  }

  /// Effective enabled domain set for a device, honouring the device-local
  /// "sync login state" toggle (§3.2, §3.4).
  ///
  /// A missing toggle value resolves to [authEnabledByDefault] (`true`).
  static Set<String> enabledDomains({Object? syncAuthEnabled}) =>
      resolveAuthDomainEnabled(syncAuthEnabled) ? all : defaultEnabled;

  /// Resolves the effective `auth` domain flag from the device-local toggle
  /// value. Unset (`null`) or non-boolean values fall back to the default.
  static bool resolveAuthDomainEnabled(Object? syncAuthEnabledSetting) {
    if (syncAuthEnabledSetting is bool) return syncAuthEnabledSetting;
    return authEnabledByDefault;
  }

  /// Default value of the "sync login state" toggle (§3.4 / §12.5).
  static const bool authEnabledByDefault = true;

  /// Membership (empty field group) merge rule per domain — the protocol §3
  /// table, transposed:
  ///
  /// | domain                                | rule                     |
  /// |---------------------------------------|--------------------------|
  /// | history (progress + meta registers)   | registerLww              |
  /// | favoriteFolder (membership + meta)    | setLwwElement            |
  /// | favoriteOrder (whole array)           | registerLww              |
  /// | favoriteLink (source binding)         | registerLww              |
  /// | favoriteComic (membership + meta)     | setLwwElement            |
  /// | readLater (membership only)           | setLwwElement            |
  /// | imageFavorite (pages + metadata)      | setLwwElement            |
  /// | setting (per key)                     | registerLww              |
  /// | comicSetting (per comic key)          | registerLww              |
  /// | comicSource (blob reference)          | registerLww              |
  /// | auth (per cookie)                     | registerLww              |
  ///
  /// [MergeRule.clearOnly] is reserved: no current Venera domain has only a
  /// clear cutoff and no per-record payload.
  static const Map<String, MergeRule> _membershipRules = <String, MergeRule>{
    history: MergeRule.registerLww,
    favoriteFolder: MergeRule.setLwwElement,
    favoriteOrder: MergeRule.registerLww,
    favoriteLink: MergeRule.registerLww,
    favoriteComic: MergeRule.setLwwElement,
    readLater: MergeRule.setLwwElement,
    imageFavorite: MergeRule.setLwwElement,
    setting: MergeRule.registerLww,
    comicSetting: MergeRule.registerLww,
    comicSource: MergeRule.registerLww,
    auth: MergeRule.registerLww,
  };
}

/// How two conflicting versions of one record/element are merged (D2, §3).
enum MergeRule {
  /// Last-writer-wins register, compared with the unified version order
  /// `(HLC, seq)` (§5.2). Deletes are tombstones and only win when newer.
  registerLww,

  /// LWW-Element-Set: each element keeps an add version and a remove version,
  /// visible while `add > remove` (§3.1). Delete/re-add ordering is handled by
  /// the same version comparison; a domain-wide `clear` cutoff is applied
  /// before either version is considered.
  setLwwElement,

  /// Only a domain-wide `clear` cutoff is meaningful; no per-record payload.
  /// Reserved by this model, no current Venera domain uses it.
  clearOnly;

  /// Whether this rule stores a JSON payload register.
  bool get isRegister => this == registerLww;

  /// Whether this rule stores set membership versions (`add`/`del`).
  bool get isSetLike => this == setLwwElement;
}

/// Field group names (`f` on the wire).
///
/// A record without a meaningful field group uses [empty]; the protocol's
/// `value` / `blob` columns in the §3 table are payload keys, not field-group
/// names (see the `comicSource` example in appendix B, where `f` is `""`).
abstract final class SyncFields {
  /// The record itself, also the field group of set-membership ops.
  static const String empty = '';

  /// Reading-progress register of [SyncDomains.history] (§3).
  static const String progress = 'progress';

  /// Metadata register of `history` / `favoriteFolder` / `favoriteComic` (§3).
  static const String meta = 'meta';

  /// Both field groups of [SyncDomains.history]; a delete or clear must cover
  /// each of them (§3.5).
  static const List<String> historyGroups = <String>[progress, meta];
}

/// Factories for wire keys (`k`), one per domain (§3).
///
/// Every key is a compact JSON array ([SyncKey]); segments are opaque strings
/// and may contain `/`, `@`, `#`, `"`, `\` or unicode. Never build a key with
/// string interpolation and never split an encoded key (§3, D14, §3.6).
abstract final class SyncKeys {
  /// `history` key: `[comicId, comicType]` (§3).
  static SyncKey historyKey(String comicId, String comicType) =>
      SyncKey(<String>[comicId, comicType]);

  /// `favoriteFolder` key: `[folderName]` (§3).
  static SyncKey favoriteFolderKey(String folder) => SyncKey(<String>[folder]);

  /// `favoriteLink` key: `[folderName]` (§3).
  static SyncKey favoriteLinkKey(String folder) => SyncKey(<String>[folder]);

  /// `favoriteComic` key: `[folderName, comicId, comicType]` (§3).
  static SyncKey favoriteComicKey(
    String folder,
    String comicId,
    String comicType,
  ) => SyncKey(<String>[folder, comicId, comicType]);

  /// `readLater` key: `[comicId, comicType]` (§3).
  static SyncKey readLaterKey(String comicId, String comicType) =>
      SyncKey(<String>[comicId, comicType]);

  /// `imageFavorite` key: `[comicKey, ep, page]` (§3).
  static SyncKey imageFavoriteKey(String comicKey, int ep, int page) =>
      SyncKey(<String>[comicKey, '$ep', '$page']);

  /// `setting` key: `[settingKey]` (§3).
  static SyncKey settingKey(String key) => SyncKey(<String>[key]);

  /// `comicSetting` key: `[comicKey, settingKey]` (§3).
  static SyncKey comicSettingKey(String comicKey, String key) =>
      SyncKey(<String>[comicKey, key]);

  /// `comicSource` key: `[sourceKey]` (§3).
  static SyncKey comicSourceKey(String sourceKey) =>
      SyncKey(<String>[sourceKey]);

  /// `auth` (cookie) key: `[cookieDomain, cookiePath, cookieName]` (§3.4).
  ///
  /// These are the cookie jar's primary-key columns `(domain, path, name)`;
  /// they may contain `@` and `/`, so they are passed as separate segments.
  static SyncKey authCookieKey(String domain, String path, String name) =>
      SyncKey(<String>[domain, path, name]);

  /// Reserved first segment of source login-state records in [SyncDomains.auth].
  ///
  /// Cookie keys always have three segments and a cookie domain cannot contain
  /// `@`, so source-data keys and cookie keys can never collide.
  static const String sourceDataPrefix = '@sourceData';

  /// `auth` (comic source login state) key: `[@sourceData, sourceKey]`.
  ///
  /// The payload is a blob reference to the source's `<key>.data` sidecar,
  /// which stores login tokens for sources such as picacg / komga / jm.
  static SyncKey sourceDataKey(String sourceKey) =>
      SyncKey(<String>[sourceDataPrefix, sourceKey]);

  /// Whether [parts] is a [sourceDataKey] (rather than a cookie key).
  static bool isSourceDataKey(List<String> parts) =>
      parts.length == 2 && parts[0] == sourceDataPrefix;
}

/// Top-level aliases for [SyncKeys].
SyncKey historyKey(String comicId, String comicType) =>
    SyncKeys.historyKey(comicId, comicType);

/// Top-level alias for [SyncKeys.favoriteFolderKey].
SyncKey favoriteFolderKey(String folder) => SyncKeys.favoriteFolderKey(folder);

/// Top-level alias for [SyncKeys.favoriteLinkKey].
SyncKey favoriteLinkKey(String folder) => SyncKeys.favoriteLinkKey(folder);

/// Top-level alias for [SyncKeys.favoriteComicKey].
SyncKey favoriteComicKey(String folder, String comicId, String comicType) =>
    SyncKeys.favoriteComicKey(folder, comicId, comicType);

/// Top-level alias for [SyncKeys.readLaterKey].
SyncKey readLaterKey(String comicId, String comicType) =>
    SyncKeys.readLaterKey(comicId, comicType);

/// Top-level alias for [SyncKeys.imageFavoriteKey].
SyncKey imageFavoriteKey(String comicKey, int ep, int page) =>
    SyncKeys.imageFavoriteKey(comicKey, ep, page);

/// Top-level alias for [SyncKeys.settingKey].
SyncKey settingKey(String key) => SyncKeys.settingKey(key);

/// Top-level alias for [SyncKeys.comicSettingKey].
SyncKey comicSettingKey(String comicKey, String key) =>
    SyncKeys.comicSettingKey(comicKey, key);

/// Top-level alias for [SyncKeys.comicSourceKey].
SyncKey comicSourceKey(String sourceKey) => SyncKeys.comicSourceKey(sourceKey);

/// Top-level alias for [SyncKeys.authCookieKey].
SyncKey authCookieKey(String domain, String path, String name) =>
    SyncKeys.authCookieKey(domain, path, name);

/// Device-local setting keys from protocol §3.2.
///
/// These settings never enter the wire protocol: connection details, device
/// identity and per-device UX differences. Every other settings key is synced
/// as a `setting/<key>` LWW register (§3, §3.2).
abstract final class SyncSettingKeys {
  /// WebDAV connection configuration (URL / user / password).
  static const String webdav = 'webdav';

  /// Whether the WebDAV connection goes through the app proxy.
  static const String webdavProxyEnabled = 'webdavProxyEnabled';

  /// Backup WebDAV connection configuration.
  static const String backupWebdav = 'backupWebdav';

  /// Backup WebDAV target path.
  static const String backupWebdavPath = 'backupWebdavPath';

  /// Whether WebDAV backup sync is enabled on this device.
  static const String backupWebdavSyncEnabled = 'backupWebdavSyncEnabled';

  /// Proxy configuration.
  static const String proxy = 'proxy';

  /// TLS SNI switch.
  static const String sni = 'sni';

  /// Whether DNS overrides are enabled.
  static const String enableDnsOverrides = 'enableDnsOverrides';

  /// DNS override table.
  static const String dnsOverrides = 'dnsOverrides';

  /// Remote comic source list URL.
  static const String comicSourceListUrl = 'comicSourceListUrl';

  /// Installation-level device id (also the remote branch name).
  static const String deviceId = 'deviceId';

  /// v1 last-sync timestamp; not used by v2, kept device-local (§10).
  static const String lastSyncTime = 'lastSyncTime';

  /// Legacy v1 custom disable-sync field list.
  static const String disableSyncFields = 'disableSyncFields';

  /// Explicitly device-specific settings payload.
  static const String deviceSpecificSettings = 'deviceSpecificSettings';

  /// "同步登录状态" toggle. The switch itself must not sync, otherwise a
  /// remote device could flip it (§3.2, §3.4).
  static const String syncAuthEnabled = 'syncAuthEnabled';

  /// UI font scale.
  static const String uiFontScale = 'uiFontScale';

  /// Comment font size.
  static const String commentFontSize = 'commentFontSize';

  /// Image favorites display mode.
  static const String imageFavoritesDisplayType = 'imageFavoritesDisplayType';

  /// Search history.
  static const String searchHistory = 'searchHistory';

  /// Implicit data cache.
  static const String implicitData = 'implicitData';

  /// The complete §3.2 device-local key set.
  static const Set<String> deviceLocal = <String>{
    webdav,
    webdavProxyEnabled,
    backupWebdav,
    backupWebdavPath,
    backupWebdavSyncEnabled,
    proxy,
    sni,
    enableDnsOverrides,
    dnsOverrides,
    comicSourceListUrl,
    deviceId,
    lastSyncTime,
    disableSyncFields,
    deviceSpecificSettings,
    syncAuthEnabled,
    uiFontScale,
    commentFontSize,
    imageFavoritesDisplayType,
    searchHistory,
    implicitData,
  };

  /// Optional explicit allowlist of synced settings keys.
  ///
  /// The protocol syncs *every* settings key that is not in [deviceLocal]
  /// (§3.2), so this stays empty; it exists as the stable place to introduce
  /// an allowlist later without touching call sites.
  static const Set<String> defaultSyncedSettingKeys = <String>{};

  /// Whether [key] is device-local and must not be emitted/applied (§3.2).
  static bool isDeviceLocalSetting(String key) => deviceLocal.contains(key);

  /// Whether [key] participates in sync as a `setting/<key>` LWW register.
  static bool isSyncedSetting(String key) => !deviceLocal.contains(key);
}

/// Whether [key] is a device-local setting key (§3.2).
bool isDeviceLocalSetting(String key) =>
    SyncSettingKeys.isDeviceLocalSetting(key);

/// Whether the `auth` (cookie / login state) domain is enabled by default.
///
/// Product decision (§3.4, §12.5): synced login state is on by default,
/// matching v1, and can be turned off with the device-local "同步登录状态"
/// toggle ([SyncSettingKeys.syncAuthEnabled]). The toggle value itself never
/// syncs (§3.2).
const bool authEnabledByDefault = SyncDomains.authEnabledByDefault;

/// Whether [domain] is the login-state domain (§3.4).
bool isAuthDomain(String domain) => SyncDomains.isAuthDomain(domain);

/// Resolves the effective `auth` domain flag from the device-local toggle
/// value; unset or non-boolean values fall back to [authEnabledByDefault].
bool resolveAuthDomainEnabled(Object? syncAuthEnabledSetting) =>
    SyncDomains.resolveAuthDomainEnabled(syncAuthEnabledSetting);

/// Merge rule for [domain]'s membership / empty-field-group ops; see
/// [SyncDomains.mergeRuleFor].
MergeRule mergeRuleFor(String domain) => SyncDomains.mergeRuleFor(domain);

/// Merge rule for one field group of [domain]; see [SyncDomains.ruleForField].
MergeRule ruleForField(String domain, String field) =>
    SyncDomains.ruleForField(domain, field);
