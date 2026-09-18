abstract final class SensitiveDataSanitizer {
  static final _sensitiveKey = RegExp(
    r'(authorization|cookie|password|passwd|token|secret|signature|credentials?|session[-_]?id|private[-_]?data|api[-_]?key|ipc[-_]?key|(?:^|[-_])auth(?:$|[-_]))',
    caseSensitive: false,
  );
  static final _secretQueryKey = RegExp(
    r'^(auth|authorization|cookie|password|passwd|token|access_token|refresh_token|secret|signature|key|api[-_]?key|credential|session|session[-_]?id)$',
    caseSensitive: false,
  );
  static final _assignment = RegExp(
    r'\b(auth|authorization|cookie|password|passwd|token|secret|signature|credentials?|session|api[-_]?key)\b(\s*[:=]\s*)([^\s,;]+)',
    caseSensitive: false,
  );
  static final _bearer = RegExp(
    r'\bbearer\s+[A-Za-z0-9._~+\-/]+=*',
    caseSensitive: false,
  );
  static final _url = RegExp(r'''https?://[^\s<>"']+''');

  static Object? sanitizeValue(Object? value, {String? key}) {
    if (key != null && _sensitiveKey.hasMatch(key)) return '[REDACTED]';
    if (value is Map) {
      return value.map(
        (entryKey, entryValue) => MapEntry(
          entryKey.toString(),
          sanitizeValue(entryValue, key: entryKey.toString()),
        ),
      );
    }
    if (value is Iterable) {
      return value.map((item) => sanitizeValue(item)).toList();
    }
    if (value is String) return sanitizeText(value);
    return value;
  }

  static String sanitizeText(String value) {
    var result = value.replaceAll(_bearer, 'Bearer [REDACTED]');
    result = result.replaceAllMapped(
      _assignment,
      (match) => '${match[1]}${match[2]}[REDACTED]',
    );
    return result.replaceAllMapped(_url, (match) => sanitizeUrl(match[0]!));
  }

  static String sanitizeUrl(String value) {
    var trailing = '';
    while (value.isNotEmpty && '.,);]'.contains(value[value.length - 1])) {
      trailing = value[value.length - 1] + trailing;
      value = value.substring(0, value.length - 1);
    }
    var uri = Uri.tryParse(value);
    if (uri == null) return '$value$trailing';
    var pairs = <String>[];
    for (var entry in uri.queryParametersAll.entries) {
      for (var item in entry.value) {
        var safeValue = _secretQueryKey.hasMatch(entry.key)
            ? '[REDACTED]'
            : item;
        pairs.add(
          '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(safeValue)}',
        );
      }
    }
    return '${uri.replace(userInfo: uri.userInfo.isEmpty ? null : 'REDACTED', query: uri.hasQuery ? pairs.join('&') : null)}$trailing';
  }
}
