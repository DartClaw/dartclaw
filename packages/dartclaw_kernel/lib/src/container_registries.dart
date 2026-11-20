import 'dart:io' show InternetAddress;

import 'package:collection/collection.dart';

/// One pinned registry origin and the mirror route that represents it.
final class RegistryUpstream {
  /// Mirror path segment the container requests under (`/<route>/…`).
  final String route;

  /// Exact origin (`scheme://host[:port]`) the host fetches from.
  final String origin;

  /// Creates an upstream pin. Validation belongs to the config parser alone.
  const new({required this.route, required this.origin});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RegistryUpstream && route == other.route && origin == other.origin;

  @override
  int get hashCode => Object.hash(route, origin);
}

/// Which upstream JSON responses carry URLs to rewrite onto the mirror.
final class RegistryJsonRewrite {
  /// The upstream route whose responses this rule covers.
  final String route;

  /// Upstream request path prefix the rule applies under.
  final String pathPrefix;

  /// Media types the rule applies to, compared case-insensitively without parameters.
  final List<String> contentTypes;

  /// Creates a rewrite rule.
  const new({required this.route, required this.pathPrefix, required this.contentTypes});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RegistryJsonRewrite &&
          route == other.route &&
          pathPrefix == other.pathPrefix &&
          const ListEquality<String>().equals(contentTypes, other.contentTypes);

  @override
  int get hashCode => Object.hash(route, pathPrefix, Object.hashAll(contentTypes));
}

/// One package-registry ecosystem the host mirror serves to `workspace` containers
/// (ADR-062): its pins, the client variables pointing a package manager at the
/// mirror, and the JSON responses whose pinned URLs are rewritten.
///
/// The type validates nothing; [parseRegistryRecords] is the one validating
/// authority, so tests may build records with loopback origins directly.
final class RegistryRecord {
  /// The `container.registries` key, also the audited ecosystem name.
  final String name;

  /// Whether the mirror serves this record.
  final bool enabled;

  /// Pinned origins, each under its own route.
  final List<RegistryUpstream> upstreams;

  /// Client variables; [mirrorPlaceholder] in a value expands to the mirror base.
  final Map<String, String> env;

  /// JSON rewrite rules.
  final List<RegistryJsonRewrite> rewriteJson;

  /// The token an `env` value names the mirror base with.
  static const mirrorPlaceholder = '{mirror}';

  /// Creates a registry record.
  const new({
    required this.name,
    this.enabled = true,
    required this.upstreams,
    this.env = const {},
    this.rewriteJson = const [],
  });

  /// [env] with [mirrorPlaceholder] expanded to [mirrorBase].
  Map<String, String> clientEnvironment(String mirrorBase) => {
    for (final entry in env.entries) entry.key: entry.value.replaceAll(mirrorPlaceholder, mirrorBase),
  };

  RegistryRecord _withEnabled(bool enabled) =>
      RegistryRecord(name: name, enabled: enabled, upstreams: upstreams, env: env, rewriteJson: rewriteJson);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RegistryRecord &&
          name == other.name &&
          enabled == other.enabled &&
          const ListEquality<RegistryUpstream>().equals(upstreams, other.upstreams) &&
          const MapEquality<String, String>().equals(env, other.env) &&
          const ListEquality<RegistryJsonRewrite>().equals(rewriteJson, other.rewriteJson);

  @override
  int get hashCode => Object.hash(
    name,
    enabled,
    Object.hashAll(upstreams),
    Object.hashAllUnordered(env.entries.map((entry) => Object.hash(entry.key, entry.value))),
    Object.hashAll(rewriteJson),
  );
}

/// The ecosystems DartClaw ships, as the same records an operator writes.
///
/// `go` ships disabled: proxy.golang.org fetches any module path it is asked
/// for, so enabling it relays requests to hosts the container chooses.
const builtInRegistryRecords = <RegistryRecord>[
  RegistryRecord(
    name: 'pub',
    upstreams: [RegistryUpstream(route: 'pub', origin: 'https://pub.dev')],
    env: {'PUB_HOSTED_URL': '{mirror}/pub'},
    rewriteJson: [
      RegistryJsonRewrite(route: 'pub', pathPrefix: '/api/packages/', contentTypes: ['application/json']),
    ],
  ),
  RegistryRecord(
    name: 'npm',
    upstreams: [RegistryUpstream(route: 'npm', origin: 'https://registry.npmjs.org')],
    // The trailing slash is what bun needs to resolve the registry.
    env: {'npm_config_registry': '{mirror}/npm/', 'npm_config_audit': 'false'},
  ),
  RegistryRecord(
    name: 'pypi',
    upstreams: [
      RegistryUpstream(route: 'pypi', origin: 'https://pypi.org'),
      RegistryUpstream(route: 'pypi-files', origin: 'https://files.pythonhosted.org'),
    ],
    env: {'PIP_INDEX_URL': '{mirror}/pypi/simple/', 'UV_DEFAULT_INDEX': '{mirror}/pypi/simple'},
    rewriteJson: [
      RegistryJsonRewrite(route: 'pypi', pathPrefix: '/simple/', contentTypes: ['application/vnd.pypi.simple.v1+json']),
    ],
  ),
  // Cargo has no environment setting for source replacement; its image
  // recipe's config.toml names the `crates` route instead.
  RegistryRecord(
    name: 'crates',
    upstreams: [
      RegistryUpstream(route: 'crates', origin: 'https://index.crates.io'),
      RegistryUpstream(route: 'crates-dl', origin: 'https://static.crates.io'),
    ],
    rewriteJson: [
      RegistryJsonRewrite(route: 'crates', pathPrefix: '/config.json', contentTypes: ['application/octet-stream']),
    ],
  ),
  RegistryRecord(
    name: 'go',
    enabled: false,
    upstreams: [
      RegistryUpstream(route: 'go', origin: 'https://proxy.golang.org'),
      RegistryUpstream(route: 'gosum', origin: 'https://sum.golang.org'),
    ],
    env: {'GOPROXY': '{mirror}/go', 'GOSUMDB': 'sum.golang.org {mirror}/gosum', 'GOTOOLCHAIN': 'local'},
  ),
];

const _recordKeys = {'enabled', 'upstreams', 'env', 'rewrite_json'};
final _routePattern = RegExp(r'^[a-z0-9-]+$');
final _envKeyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
// Numeric host spellings (decimal, octal, hex labels) that resolvers read as an
// IPv4 address although InternetAddress.tryParse rejects them.
final _numericHost = RegExp(r'^(0x[0-9a-f]*|[0-9]+)(\.(0x[0-9a-f]*|[0-9]+))*\.?$', caseSensitive: false);

/// The effective records: [builtInRegistryRecords] overlaid by the
/// `container.registries` map [raw], validated once.
///
/// An entry carrying only `enabled` toggles the built-in of that name; any
/// other entry replaces the record of its name whole, or adds one, with
/// `enabled` defaulting to true. Throws [FormatException] naming the offending
/// `container.registries.<name>…` path and rule. A disabled record is held to
/// type checks only.
List<RegistryRecord> parseRegistryRecords(Object? raw) {
  const root = 'container.registries';
  if (raw == null) return builtInRegistryRecords;
  if (raw is! Map) throw const FormatException('$root must be a map of registry records keyed by name.');

  final records = {for (final record in builtInRegistryRecords) record.name: record};
  for (final entry in raw.entries) {
    final name = entry.key;
    if (name is! String) throw FormatException('$root: record name $name must be a string.');
    final path = '$root.$name';
    if (!_routePattern.hasMatch(name)) {
      throw FormatException('$path: a record name must be one segment of lowercase letters, digits and hyphens.');
    }
    final value = entry.value;
    if (value is! Map) throw FormatException('$path must be a map.');
    for (final key in value.keys) {
      if (!_recordKeys.contains(key)) {
        throw FormatException('$path.$key is not a registry record field (${_recordKeys.join(', ')}).');
      }
    }
    final enabled = value['enabled'];
    if (enabled != null && enabled is! bool) throw FormatException('$path.enabled must be true or false.');
    final builtIn = records[name];
    if (value.length == 1 && enabled is bool && builtIn != null) {
      records[name] = builtIn._withEnabled(enabled);
      continue;
    }
    records[name] = RegistryRecord(
      name: name,
      enabled: enabled as bool? ?? true,
      upstreams: _upstreams(value['upstreams'], '$path.upstreams'),
      env: _env(value['env'], '$path.env'),
      rewriteJson: _rewrites(value['rewrite_json'], '$path.rewrite_json'),
    );
  }

  final routes = <String, String>{};
  final envKeys = <String, String>{};
  for (final record in records.values.where((record) => record.enabled)) {
    final path = '$root.${record.name}';
    if (record.upstreams.isEmpty) {
      throw FormatException('$path.upstreams: an enabled record needs at least one upstream.');
    }
    for (final (index, upstream) in record.upstreams.indexed) {
      final at = '$path.upstreams[$index]';
      _checkOrigin(upstream.origin, '$at.origin');
      if (!_routePattern.hasMatch(upstream.route)) {
        throw FormatException(
          '$at.route: "${upstream.route}" must be one path segment of lowercase letters, digits and hyphens.',
        );
      }
      final owner = routes[upstream.route];
      if (owner != null) {
        throw FormatException('$at.route: "${upstream.route}" is already a route of record "$owner".');
      }
      routes[upstream.route] = record.name;
    }
    for (final key in record.env.keys) {
      if (!_envKeyPattern.hasMatch(key)) {
        throw FormatException('$path.env.$key is not a POSIX environment variable name.');
      }
      final owner = envKeys[key.toUpperCase()];
      if (owner != null) {
        throw FormatException(
          '$path.env.$key: record "$owner" already sets this variable (names compare case-insensitively).',
        );
      }
      envKeys[key.toUpperCase()] = record.name;
    }
    final ownRoutes = {for (final upstream in record.upstreams) upstream.route};
    for (final (index, rule) in record.rewriteJson.indexed) {
      if (!ownRoutes.contains(rule.route)) {
        throw FormatException(
          '$path.rewrite_json[$index].route: "${rule.route}" is not an upstream route of this record.',
        );
      }
    }
  }
  return List.unmodifiable(records.values);
}

void _checkOrigin(String origin, String path) {
  final uri = Uri.tryParse(origin);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority || uri.host.isEmpty) {
    throw FormatException('$path: "$origin" is not an origin.');
  }
  if (uri.scheme != 'https') throw FormatException('$path: "$origin" must use https.');
  if (uri.userInfo.isNotEmpty) throw FormatException('$path: "$origin" must not carry userinfo.');
  if (uri.path.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    throw FormatException('$path: "$origin" must be an exact origin with no path, query or fragment.');
  }
  if (InternetAddress.tryParse(uri.host) != null || _numericHost.hasMatch(uri.host)) {
    throw FormatException('$path: "$origin" must name a host, not an IP address.');
  }
}

List<RegistryUpstream> _upstreams(Object? raw, String path) {
  if (raw == null) return const [];
  if (raw is! List) throw FormatException('$path must be a list of {route, origin} entries.');
  return List.unmodifiable([
    for (final (index, item) in raw.indexed)
      if (item is! Map)
        throw FormatException('$path[$index] must be a map with route and origin.')
      else ...[
        for (final key in item.keys)
          if (key != 'route' && key != 'origin') throw FormatException('$path[$index].$key is not an upstream field.'),
        RegistryUpstream(
          route: _string(item['route'], '$path[$index].route'),
          origin: _string(item['origin'], '$path[$index].origin'),
        ),
      ],
  ]);
}

Map<String, String> _env(Object? raw, String path) {
  if (raw == null) return const {};
  if (raw is! Map) throw FormatException('$path must be a map of variable names to string values.');
  return Map.unmodifiable({
    for (final entry in raw.entries)
      _string(entry.key, '$path key ${entry.key}'): _string(entry.value, '$path.${entry.key}'),
  });
}

List<RegistryJsonRewrite> _rewrites(Object? raw, String path) {
  if (raw == null) return const [];
  if (raw is! List) throw FormatException('$path must be a list of {route, path_prefix, content_types} entries.');
  const keys = {'route', 'path_prefix', 'content_types'};
  return List.unmodifiable([
    for (final (index, item) in raw.indexed)
      if (item is! Map)
        throw FormatException('$path[$index] must be a map with route, path_prefix and content_types.')
      else ...[
        for (final key in item.keys)
          if (!keys.contains(key)) throw FormatException('$path[$index].$key is not a rewrite_json field.'),
        RegistryJsonRewrite(
          route: _string(item['route'], '$path[$index].route'),
          pathPrefix: _string(item['path_prefix'], '$path[$index].path_prefix'),
          contentTypes: _strings(item['content_types'], '$path[$index].content_types'),
        ),
      ],
  ]);
}

String _string(Object? value, String path) =>
    value is String ? value : throw FormatException('$path must be a string.');

List<String> _strings(Object? value, String path) => value is List && value.every((item) => item is String)
    ? List.unmodifiable(value.cast<String>())
    : throw FormatException('$path must be a list of strings.');
