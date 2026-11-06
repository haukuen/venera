import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/sync/domains.dart';
import 'package:venera/sync/hlc.dart';
import 'package:venera/sync/key_codec.dart';
import 'package:venera/sync/op.dart';
import 'package:venera/sync/version.dart';

const String _deviceId = 'a1b2c3d4';

/// Expected membership (empty field group) rule per domain, mirroring the
/// protocol §3 table. Keep this list independent from the implementation so a
/// wrong mapping fails the test instead of silently agreeing with itself.
const Map<String, MergeRule> _expectedMembershipRules = <String, MergeRule>{
  SyncDomains.history: MergeRule.registerLww,
  SyncDomains.favoriteFolder: MergeRule.setLwwElement,
  SyncDomains.favoriteOrder: MergeRule.registerLww,
  SyncDomains.favoriteLink: MergeRule.registerLww,
  SyncDomains.favoriteComic: MergeRule.setLwwElement,
  SyncDomains.readLater: MergeRule.setLwwElement,
  SyncDomains.imageFavorite: MergeRule.setLwwElement,
  SyncDomains.setting: MergeRule.registerLww,
  SyncDomains.comicSetting: MergeRule.registerLww,
  SyncDomains.comicSource: MergeRule.registerLww,
  SyncDomains.auth: MergeRule.registerLww,
};

/// Representative key for every domain, built through the public factories.
///
/// `favoriteOrder` has no factory: the protocol only says the register key is
/// a single value ("单值", §3), so a test-local constant is used here.
SyncKey _sampleKey(String domain) => switch (domain) {
  SyncDomains.history => historyKey('x@y/漫画', '1'),
  SyncDomains.favoriteFolder => favoriteFolderKey('默认/a/b'),
  SyncDomains.favoriteOrder => SyncKey(const <String>['order']),
  SyncDomains.favoriteLink => favoriteLinkKey('默认/a/b'),
  SyncDomains.favoriteComic => favoriteComicKey('默认/a/b', 'x@y', '1'),
  SyncDomains.readLater => readLaterKey('x@y', '1'),
  SyncDomains.imageFavorite => imageFavoriteKey('source/x@y', 3, 12),
  SyncDomains.setting => settingKey('theme'),
  SyncDomains.comicSetting => comicSettingKey('source/x@y', 'readerMode'),
  SyncDomains.comicSource => comicSourceKey('copymanga'),
  SyncDomains.auth => authCookieKey('.example.com', '/a@b/c', 'sid"\\'),
  _ => throw StateError('missing sample key for $domain'),
};

/// Representative field group for every domain.
String _sampleField(String domain) => switch (domain) {
  SyncDomains.history => SyncFields.progress,
  SyncDomains.favoriteFolder || SyncDomains.favoriteComic => SyncFields.meta,
  _ => SyncFields.empty,
};

Version _version(int seq) =>
    Version(Hlc(ms: 1762345678901, counter: 0, deviceId: _deviceId), seq);

void main() {
  group('SyncDomains', () {
    test('lists exactly the protocol v2 domains', () {
      expect(SyncDomains.all, <String>{
        'history',
        'favoriteFolder',
        'favoriteOrder',
        'favoriteLink',
        'favoriteComic',
        'readLater',
        'imageFavorite',
        'setting',
        'comicSetting',
        'comicSource',
        'auth',
      });
      expect(SyncDomains.all, hasLength(11));

      // No duplicates: all domains are unique strings.
      final list = SyncDomains.all.toList();
      expect(list.toSet(), hasLength(list.length));

      for (final domain in SyncDomains.all) {
        expect(SyncDomains.isValidDomain(domain), isTrue, reason: domain);
        expect(syncDomainRegExp.hasMatch(domain), isTrue, reason: domain);
      }
    });

    test('every domain produces a SyncOp the wire contract accepts', () {
      for (final domain in SyncDomains.all) {
        final key = _sampleKey(domain);
        final field = _sampleField(domain);
        final op = SyncOp(
          deviceId: _deviceId,
          seq: 1,
          version: _version(1),
          domain: domain,
          key: key,
          field: field,
          kind: SyncOpKind.upsert,
          data: const <String, Object?>{'value': 1},
        );

        // Round-trip through the wire format so domain / field / key are
        // validated by the contract codecs, not just by this model.
        final decoded = SyncOp.fromJson(
          (jsonDecode(jsonEncode(op.toJson())) as Map).cast<String, Object?>(),
        );
        expect(decoded.domain, domain);
        expect(decoded.key, key);
        expect(decoded.field, field);
        expect(decoded.kind, SyncOpKind.upsert);
      }
    });

    test('membership (add) and clear ops are valid for set domains', () {
      for (final domain in SyncDomains.all) {
        final membershipRule = _expectedMembershipRules[domain]!;

        // Every domain supports a domain-wide clear (§3.1).
        final clear = SyncOp(
          deviceId: _deviceId,
          seq: 2,
          version: _version(2),
          domain: domain,
          field: SyncFields.empty,
          kind: SyncOpKind.clear,
        );
        expect(clear.isClear, isTrue);
        expect(clear.toJson()['k'], '*');

        if (membershipRule != MergeRule.setLwwElement) continue;

        final add = SyncOp(
          deviceId: _deviceId,
          seq: 3,
          version: _version(3),
          domain: domain,
          key: _sampleKey(domain),
          field: SyncFields.empty,
          kind: SyncOpKind.add,
        );
        expect(add.isSetLike, isTrue);
        final del = SyncOp(
          deviceId: _deviceId,
          seq: 4,
          version: _version(4),
          domain: domain,
          key: _sampleKey(domain),
          field: SyncFields.empty,
          kind: SyncOpKind.del,
        );
        expect(del.isSetLike, isTrue);
      }
    });

    test('defaultEnabled is all domains except auth', () {
      expect(
        SyncDomains.defaultEnabled,
        SyncDomains.all.difference(<String>{SyncDomains.auth}),
      );
      expect(SyncDomains.defaultEnabled, hasLength(SyncDomains.all.length - 1));
      expect(SyncDomains.defaultEnabled.contains(SyncDomains.auth), isFalse);
      for (final domain in SyncDomains.all) {
        expect(
          SyncDomains.isDefaultEnabled(domain),
          domain != SyncDomains.auth,
          reason: domain,
        );
      }
    });

    test('enabledDomains honours the device-local auth toggle', () {
      expect(SyncDomains.enabledDomains(), SyncDomains.all);
      expect(
        SyncDomains.enabledDomains(syncAuthEnabled: null),
        SyncDomains.all,
      );
      expect(
        SyncDomains.enabledDomains(syncAuthEnabled: true),
        SyncDomains.all,
      );
      expect(
        SyncDomains.enabledDomains(syncAuthEnabled: false),
        SyncDomains.defaultEnabled,
      );
    });

    test('isValidDomain only accepts known domain ids', () {
      for (final unknown in <String>[
        '',
        'History',
        'history ',
        ' history',
        'history/x',
        'history-x',
        'no-such-domain',
        'a' * 40,
      ]) {
        expect(SyncDomains.isValidDomain(unknown), isFalse, reason: unknown);
      }
    });
  });

  group('MergeRule mapping', () {
    test('every known domain has the §3 membership merge rule', () {
      expect(
        _expectedMembershipRules.keys.toSet(),
        SyncDomains.all,
        reason: 'expected rules must cover exactly the known domains',
      );
      for (final entry in _expectedMembershipRules.entries) {
        expect(mergeRuleFor(entry.key), entry.value, reason: entry.key);
        expect(SyncDomains.mergeRuleFor(entry.key), entry.value);
      }
    });

    test('unknown domains are rejected by rule lookups', () {
      for (final unknown in <String>['', 'History', 'nope', 'auth/x']) {
        expect(
          () => mergeRuleFor(unknown),
          throwsArgumentError,
          reason: unknown,
        );
        expect(
          () => ruleForField(unknown, SyncFields.empty),
          throwsArgumentError,
        );
        expect(() => SyncDomains.mergeRuleFor(unknown), throwsArgumentError);
        expect(
          () => SyncDomains.ruleForField(unknown, SyncFields.meta),
          throwsArgumentError,
        );
      }
    });

    test('named field groups are registers, membership follows the domain', () {
      for (final domain in SyncDomains.all) {
        expect(
          ruleForField(domain, SyncFields.empty),
          mergeRuleFor(domain),
          reason: '$domain membership',
        );
        expect(
          ruleForField(domain, SyncFields.progress),
          MergeRule.registerLww,
          reason: '$domain progress',
        );
        expect(
          ruleForField(domain, SyncFields.meta),
          MergeRule.registerLww,
          reason: '$domain meta',
        );
        // Unknown named groups are treated as registers for forward
        // compatibility with newer schema versions.
        expect(
          ruleForField(domain, 'futureFieldGroup'),
          MergeRule.registerLww,
          reason: domain,
        );
      }
    });

    test('mixed domains mix membership sets with meta registers', () {
      expect(SyncDomains.mixedDomains, <String>{
        SyncDomains.favoriteFolder,
        SyncDomains.favoriteComic,
        SyncDomains.imageFavorite,
      });

      for (final domain in SyncDomains.all) {
        final isMixed = SyncDomains.mixedDomains.contains(domain);
        expect(SyncDomains.isMixedDomain(domain), isMixed, reason: domain);
        expect(
          SyncDomains.isSetDomain(domain),
          isMixed || domain == SyncDomains.readLater,
          reason: domain,
        );
        expect(
          ruleForField(domain, SyncFields.meta),
          MergeRule.registerLww,
          reason: domain,
        );
      }

      // readLater is set-only (membership, no register fields).
      expect(SyncDomains.isSetDomain(SyncDomains.readLater), isTrue);
      expect(SyncDomains.isMixedDomain(SyncDomains.readLater), isFalse);

      // history is register-only (two field groups, no set membership).
      expect(SyncDomains.isSetDomain(SyncDomains.history), isFalse);
      expect(SyncDomains.isMixedDomain(SyncDomains.history), isFalse);
    });

    test('clearOnly is reserved and unused by every current domain', () {
      expect(MergeRule.values, contains(MergeRule.clearOnly));
      expect(
        SyncDomains.all.where(
          (domain) => mergeRuleFor(domain) == MergeRule.clearOnly,
        ),
        isEmpty,
      );
      expect(MergeRule.clearOnly.isRegister, isFalse);
      expect(MergeRule.clearOnly.isSetLike, isFalse);
      expect(MergeRule.registerLww.isRegister, isTrue);
      expect(MergeRule.setLwwElement.isSetLike, isTrue);
    });

    test('SyncFields matches the protocol field groups', () {
      expect(SyncFields.empty, '');
      expect(SyncFields.progress, 'progress');
      expect(SyncFields.meta, 'meta');
      expect(SyncFields.historyGroups, <String>[
        SyncFields.progress,
        SyncFields.meta,
      ]);
      for (final field in <String>[
        SyncFields.empty,
        SyncFields.progress,
        SyncFields.meta,
      ]) {
        expect(syncFieldRegExp.hasMatch(field), isTrue, reason: field);
      }
    });
  });

  group('key factories', () {
    test('encode as compact JSON arrays, never separator-joined', () {
      expect(historyKey('x@y', '1').encode(), '["x@y","1"]');
      expect(favoriteFolderKey('a/b').encode(), '["a/b"]');
      expect(favoriteLinkKey('默认').encode(), '["默认"]');
      expect(favoriteComicKey('a/b', 'x@y', '1').encode(), '["a/b","x@y","1"]');
      expect(readLaterKey('x@y', '1').encode(), '["x@y","1"]');
      expect(
        imageFavoriteKey('source/x@y', 3, 12).encode(),
        '["source/x@y","3","12"]',
      );
      expect(settingKey('theme').encode(), '["theme"]');
      expect(
        comicSettingKey('source/x@y', 'readerMode').encode(),
        '["source/x@y","readerMode"]',
      );
      expect(comicSourceKey('copymanga').encode(), '["copymanga"]');
      expect(
        authCookieKey('.example.com', '/a@b/c', 'sid').encode(),
        jsonEncode(const <String>['.example.com', '/a@b/c', 'sid']),
      );
    });

    test('all top-level aliases match the SyncKeys factories', () {
      expect(historyKey('a', 'b'), SyncKeys.historyKey('a', 'b'));
      expect(favoriteFolderKey('a'), SyncKeys.favoriteFolderKey('a'));
      expect(favoriteLinkKey('a'), SyncKeys.favoriteLinkKey('a'));
      expect(
        favoriteComicKey('a', 'b', 'c'),
        SyncKeys.favoriteComicKey('a', 'b', 'c'),
      );
      expect(readLaterKey('a', 'b'), SyncKeys.readLaterKey('a', 'b'));
      expect(imageFavoriteKey('a', 1, 2), SyncKeys.imageFavoriteKey('a', 1, 2));
      expect(settingKey('a'), SyncKeys.settingKey('a'));
      expect(comicSettingKey('a', 'b'), SyncKeys.comicSettingKey('a', 'b'));
      expect(comicSourceKey('a'), SyncKeys.comicSourceKey('a'));
      expect(
        authCookieKey('a', 'b', 'c'),
        SyncKeys.authCookieKey('a', 'b', 'c'),
      );
    });

    test(
      'keys round-trip through JSON for separator-y and unicode segments',
      () {
        const trickySegments = <String>[
          'a/b',
          'x@y',
          '.example.com',
          '/a@b/c#d',
          '默认/漫画#1',
          'he said "hi"',
          r'a\b\c',
          'comic@source/id#ep',
          'line\nbreak\ttab',
          'emoji-📚',
          '   ',
          '',
        ];

        for (final segment in trickySegments) {
          final key = settingKey(segment);
          expect(key.parts, <String>[segment]);

          final decoded = SyncKey.decode(key.encode());
          expect(decoded, key);
          expect(decoded.parts, <String>[segment]);
        }
      },
    );

    test(
      'multi-segment keys preserve segment boundaries after a round-trip',
      () {
        const folder = '默认/a/b';
        const comicId = 'x@y#1';
        const comicType = '1';

        final favoriteComic = favoriteComicKey(folder, comicId, comicType);
        expect(favoriteComic.parts, <String>[folder, comicId, comicType]);
        expect(SyncKey.decode(favoriteComic.encode()), favoriteComic);

        final history = historyKey(comicId, comicType);
        expect(SyncKey.decode(history.encode()), history);

        const cookieDomain = '.example.com';
        const cookiePath = '/a@b/c d';
        const cookieName = 'sid@1';
        final cookie = authCookieKey(cookieDomain, cookiePath, cookieName);
        expect(cookie.parts, <String>[cookieDomain, cookiePath, cookieName]);
        expect(SyncKey.decode(cookie.encode()).parts, cookie.parts);

        final image = imageFavoriteKey('source/x@y', 3, 12);
        expect(image.parts, <String>['source/x@y', '3', '12']);
        expect(SyncKey.decode(image.encode()), image);
      },
    );

    test('different segmentation produces different keys', () {
      // 'x@y' + '1' must not collapse into 'x' + 'y@1'.
      expect(historyKey('x@y', '1'), isNot(historyKey('x', 'y@1')));
      // A folder name containing '/' stays one segment.
      expect(favoriteFolderKey('a/b').parts, hasLength(1));
      expect(
        SyncKey(const <String>['a/b']),
        isNot(SyncKey(const <String>['a', 'b'])),
      );
      // cookie (domain, path, name) triple is not a joined string.
      expect(
        authCookieKey('a', 'b/c', 'd'),
        isNot(authCookieKey('a/b', 'c', 'd')),
      );
      // Different folders are different keys.
      expect(favoriteFolderKey('默认'), isNot(favoriteFolderKey('其它')));
      expect(
        favoriteComicKey('默认', 'a', '1'),
        isNot(favoriteComicKey('其它', 'a', '1')),
      );
      expect(settingKey('theme'), isNot(settingKey('readerMode')));
      expect(comicSettingKey('a', 'k'), isNot(comicSettingKey('b', 'k')));
      expect(comicSourceKey('a'), isNot(comicSourceKey('b')));
      expect(imageFavoriteKey('k', 1, 2), isNot(imageFavoriteKey('k', 2, 1)));
    });

    test('keys exclude the domain, so identical segments compare equal', () {
      // The wire `d` field disambiguates domains; `k` is domain-free (§3).
      expect(historyKey('x', '1'), readLaterKey('x', '1'));
      expect(SyncKeys.settingKey('默认'), SyncKeys.comicSourceKey('默认'));
      expect(favoriteFolderKey('默认'), SyncKeys.comicSourceKey('默认'));
    });

    test('key factories inherit SyncKey segment limits', () {
      final maxSegment = 'a' * SyncKey.maxSegmentBytes;
      expect(settingKey(maxSegment).parts.single, maxSegment);
      expect(
        () => settingKey('a' * (SyncKey.maxSegmentBytes + 1)),
        throwsArgumentError,
      );
    });
  });

  group('device-local settings', () {
    // Keep an independent copy of the protocol §3.2 list so that a typo in the
    // implementation is caught instead of being compared against itself.
    const expectedDeviceLocal = <String>{
      'webdav',
      'webdavProxyEnabled',
      'backupWebdav',
      'backupWebdavPath',
      'backupWebdavSyncEnabled',
      'proxy',
      'sni',
      'enableDnsOverrides',
      'dnsOverrides',
      'comicSourceListUrl',
      'deviceId',
      'lastSyncTime',
      'disableSyncFields',
      'deviceSpecificSettings',
      'syncAuthEnabled',
      'uiFontScale',
      'commentFontSize',
      'imageFavoritesDisplayType',
      'searchHistory',
      'implicitData',
    };

    test('matches protocol §3.2 exactly', () {
      expect(SyncSettingKeys.deviceLocal, expectedDeviceLocal);
      expect(SyncSettingKeys.deviceLocal, hasLength(20));

      // Each public constant must equal its wire key.
      expect(<String>{
        SyncSettingKeys.webdav,
        SyncSettingKeys.webdavProxyEnabled,
        SyncSettingKeys.backupWebdav,
        SyncSettingKeys.backupWebdavPath,
        SyncSettingKeys.backupWebdavSyncEnabled,
        SyncSettingKeys.proxy,
        SyncSettingKeys.sni,
        SyncSettingKeys.enableDnsOverrides,
        SyncSettingKeys.dnsOverrides,
        SyncSettingKeys.comicSourceListUrl,
        SyncSettingKeys.deviceId,
        SyncSettingKeys.lastSyncTime,
        SyncSettingKeys.disableSyncFields,
        SyncSettingKeys.deviceSpecificSettings,
        SyncSettingKeys.syncAuthEnabled,
        SyncSettingKeys.uiFontScale,
        SyncSettingKeys.commentFontSize,
        SyncSettingKeys.imageFavoritesDisplayType,
        SyncSettingKeys.searchHistory,
        SyncSettingKeys.implicitData,
      }, expectedDeviceLocal);
    });

    test('isDeviceLocalSetting recognises every §3.2 key', () {
      for (final key in expectedDeviceLocal) {
        expect(isDeviceLocalSetting(key), isTrue, reason: key);
        expect(SyncSettingKeys.isDeviceLocalSetting(key), isTrue, reason: key);
        expect(SyncSettingKeys.isSyncedSetting(key), isFalse, reason: key);
      }
    });

    test('ordinary settings stay synced', () {
      const syncedSettings = <String>[
        'theme',
        'readerMode',
        'cacheSize',
        'language',
        'readerScreenPicNumberForLandscape',
        'autoPageTurningInterval',
        'checkUpdateOnStart',
      ];
      for (final key in syncedSettings) {
        expect(isDeviceLocalSetting(key), isFalse, reason: key);
        expect(SyncSettingKeys.isSyncedSetting(key), isTrue, reason: key);
        expect(SyncSettingKeys.deviceLocal, isNot(contains(key)), reason: key);
      }
    });

    test('the check is case-sensitive and unknown keys are synced', () {
      expect(isDeviceLocalSetting('Webdav'), isFalse);
      expect(isDeviceLocalSetting('WEBDAV'), isFalse);
      expect(isDeviceLocalSetting(''), isFalse);
      expect(isDeviceLocalSetting('no-such-setting'), isFalse);
    });

    test('defaultSyncedSettingKeys placeholder has no device-local key', () {
      expect(
        SyncSettingKeys.defaultSyncedSettingKeys.difference(
          expectedDeviceLocal,
        ),
        isEmpty,
      );
    });
  });

  group('auth domain helpers', () {
    test('auth is enabled by default but not in defaultEnabled', () {
      expect(authEnabledByDefault, isTrue);
      expect(SyncDomains.authEnabledByDefault, isTrue);
      expect(SyncDomains.all, contains(SyncDomains.auth));
      expect(SyncDomains.defaultEnabled, isNot(contains(SyncDomains.auth)));
    });

    test('isAuthDomain only matches the auth domain', () {
      expect(isAuthDomain(SyncDomains.auth), isTrue);
      expect(SyncDomains.isAuthDomain(SyncDomains.auth), isTrue);
      for (final domain in SyncDomains.all) {
        if (domain == SyncDomains.auth) continue;
        expect(isAuthDomain(domain), isFalse, reason: domain);
        expect(SyncDomains.isAuthDomain(domain), isFalse, reason: domain);
      }
      expect(isAuthDomain('Auth'), isFalse);
      expect(isAuthDomain(''), isFalse);
    });

    test('resolveAuthDomainEnabled defaults and honours the toggle', () {
      expect(resolveAuthDomainEnabled(null), isTrue);
      expect(resolveAuthDomainEnabled(true), isTrue);
      expect(resolveAuthDomainEnabled(false), isFalse);
      // Non-boolean junk falls back to the default instead of guessing.
      expect(resolveAuthDomainEnabled('false'), isTrue);
      expect(resolveAuthDomainEnabled(0), isTrue);
      expect(SyncDomains.resolveAuthDomainEnabled(false), isFalse);
    });

    test('the toggle itself is device-local and never synced', () {
      expect(SyncSettingKeys.syncAuthEnabled, 'syncAuthEnabled');
      expect(isDeviceLocalSetting(SyncSettingKeys.syncAuthEnabled), isTrue);
      expect(SyncSettingKeys.isSyncedSetting('syncAuthEnabled'), isFalse);
    });

    test('auth cookie keys are (domain, path, name) triples', () {
      final key = authCookieKey('.example.com', '/', 'session');
      expect(key.parts, hasLength(3));
      expect(key.parts, <String>['.example.com', '/', 'session']);
      final decoded = SyncKey.decode(key.encode());
      expect(decoded, key);
      expect(decoded.parts, key.parts);
    });
  });
}
