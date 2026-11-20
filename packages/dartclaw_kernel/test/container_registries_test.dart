import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

List<RegistryRecord> _load(String registries) =>
    loadYaml('container:\n  registries:\n$registries').container.registries;

RegistryRecord _named(List<RegistryRecord> records, String name) => records.singleWhere((r) => r.name == name);

void main() {
  test('built-in records match the documented set', () {
    expect(loadNoFile().container.registries, const ContainerConfig().registries);
    final records = {for (final record in const ContainerConfig().registries) record.name: record};
    expect(records.keys, ['pub', 'npm', 'pypi', 'crates', 'go']);
    expect(
      records['pub'],
      const RegistryRecord(
        name: 'pub',
        upstreams: [RegistryUpstream(route: 'pub', origin: 'https://pub.dev')],
        env: {'PUB_HOSTED_URL': '{mirror}/pub'},
        rewriteJson: [
          RegistryJsonRewrite(route: 'pub', pathPrefix: '/api/packages/', contentTypes: ['application/json']),
        ],
      ),
    );
    expect(
      records['npm'],
      const RegistryRecord(
        name: 'npm',
        upstreams: [RegistryUpstream(route: 'npm', origin: 'https://registry.npmjs.org')],
        env: {'npm_config_registry': '{mirror}/npm/', 'npm_config_audit': 'false'},
      ),
    );
    expect(
      records['pypi'],
      const RegistryRecord(
        name: 'pypi',
        upstreams: [
          RegistryUpstream(route: 'pypi', origin: 'https://pypi.org'),
          RegistryUpstream(route: 'pypi-files', origin: 'https://files.pythonhosted.org'),
        ],
        env: {'PIP_INDEX_URL': '{mirror}/pypi/simple/', 'UV_DEFAULT_INDEX': '{mirror}/pypi/simple'},
        rewriteJson: [
          RegistryJsonRewrite(
            route: 'pypi',
            pathPrefix: '/simple/',
            contentTypes: ['application/vnd.pypi.simple.v1+json'],
          ),
        ],
      ),
    );
    expect(
      records['crates'],
      const RegistryRecord(
        name: 'crates',
        upstreams: [
          RegistryUpstream(route: 'crates', origin: 'https://index.crates.io'),
          RegistryUpstream(route: 'crates-dl', origin: 'https://static.crates.io'),
        ],
        rewriteJson: [
          RegistryJsonRewrite(route: 'crates', pathPrefix: '/config.json', contentTypes: ['application/octet-stream']),
        ],
      ),
    );
    expect(
      records['go'],
      const RegistryRecord(
        name: 'go',
        enabled: false,
        upstreams: [
          RegistryUpstream(route: 'go', origin: 'https://proxy.golang.org'),
          RegistryUpstream(route: 'gosum', origin: 'https://sum.golang.org'),
        ],
        env: {'GOPROXY': '{mirror}/go', 'GOSUMDB': 'sum.golang.org {mirror}/gosum', 'GOTOOLCHAIN': 'local'},
      ),
    );
    expect(records['pypi']!.clientEnvironment('http://127.0.0.1:8082'), {
      'PIP_INDEX_URL': 'http://127.0.0.1:8082/pypi/simple/',
      'UV_DEFAULT_INDEX': 'http://127.0.0.1:8082/pypi/simple',
    });
  });

  test('instance records disable, replace and add built-ins by name', () {
    final records = _load('''
    npm:
      enabled: false
    go:
      enabled: true
    pub:
      upstreams:
        - route: pub
          origin: https://pub.example.com
      env:
        PUB_HOSTED_URL: "{mirror}/pub"
    hex:
      upstreams:
        - route: hex
          origin: https://repo.hex.pm
      env:
        HEX_MIRROR: "{mirror}/hex"
''');
    final builtIns = {for (final record in builtInRegistryRecords) record.name: record};
    expect(records.map((r) => r.name), ['pub', 'npm', 'pypi', 'crates', 'go', 'hex']);
    // Only `enabled` toggles the built-in and keeps every other field.
    final npm = _named(records, 'npm');
    expect(npm.enabled, isFalse);
    expect(npm.upstreams, builtIns['npm']!.upstreams);
    final go = _named(records, 'go');
    expect(go.enabled, isTrue);
    expect(go.env, builtIns['go']!.env);
    // Any other field replaces the whole record: no built-in field survives.
    expect(
      _named(records, 'pub'),
      const RegistryRecord(
        name: 'pub',
        upstreams: [RegistryUpstream(route: 'pub', origin: 'https://pub.example.com')],
        env: {'PUB_HOSTED_URL': '{mirror}/pub'},
      ),
    );
    // An added record with no `enabled` key is enabled.
    expect(
      _named(records, 'hex'),
      const RegistryRecord(
        name: 'hex',
        upstreams: [RegistryUpstream(route: 'hex', origin: 'https://repo.hex.pm')],
        env: {'HEX_MIRROR': '{mirror}/hex'},
      ),
    );
    expect(_named(records, 'pypi'), builtIns['pypi']);
    expect(_named(records, 'crates'), builtIns['crates']);
    expect(loadYaml('container:\n  enabled: true\n').container.registries, builtInRegistryRecords);
  });

  test('container.registries is a file-only field', () {
    final meta = ConfigMeta.fields['container.registries']!;
    expect(meta.mutability, ConfigMutability.readonly);
    expect(meta.type, ConfigFieldType.objectMap);
    final errors = ConfigValidator().validate({
      'container.registries': {
        'pub': {'enabled': false},
      },
    });
    expect(errors.single.field, 'container.registries');
    expect(errors.single.message, contains('read-only'));
  });

  group('refuses each invalid registry record naming its path', () {
    String upstream(String origin, {String route = 'x'}) =>
        '      upstreams:\n        - route: $route\n          origin: $origin\n';

    for (final (label, yaml, path, rule) in [
      (
        'an http origin',
        '    x:\n${upstream('http://x.example')}',
        'container.registries.x.upstreams[0].origin',
        'https',
      ),
      (
        'userinfo in an origin',
        '    x:\n${upstream('https://user:pw@x.example')}',
        'container.registries.x.upstreams[0].origin',
        'userinfo',
      ),
      (
        'a path on an origin',
        '    x:\n${upstream('https://x.example/simple')}',
        'container.registries.x.upstreams[0].origin',
        'exact origin',
      ),
      (
        'a query on an origin',
        '    x:\n${upstream('https://x.example?a=1')}',
        'container.registries.x.upstreams[0].origin',
        'exact origin',
      ),
      (
        'a fragment on an origin',
        '    x:\n${upstream('https://x.example#f')}',
        'container.registries.x.upstreams[0].origin',
        'exact origin',
      ),
      (
        'an IPv4 literal',
        '    x:\n${upstream('https://10.0.0.1')}',
        'container.registries.x.upstreams[0].origin',
        'IP',
      ),
      (
        'a numeric IPv4 spelling',
        '    x:\n${upstream('https://2130706433')}',
        'container.registries.x.upstreams[0].origin',
        'IP',
      ),
      ('an IPv6 literal', '    x:\n${upstream('"https://[::1]"')}', 'container.registries.x.upstreams[0].origin', 'IP'),
      (
        'a route reused across records',
        '    x:\n${upstream('https://x.example', route: 'npm')}',
        'container.registries.x.upstreams[0].route',
        'record "npm"',
      ),
      (
        'a route reused within a record',
        '    x:\n      upstreams:\n        - route: a\n          origin: https://a.example\n'
            '        - route: a\n          origin: https://b.example\n',
        'container.registries.x.upstreams[1].route',
        'record "x"',
      ),
      (
        'a route that is not one lowercase segment',
        '    x:\n${upstream('https://x.example', route: 'a/b')}',
        'container.registries.x.upstreams[0].route',
        'one path segment',
      ),
      (
        'a route with uppercase letters',
        '    x:\n${upstream('https://x.example', route: 'Pub2')}',
        'container.registries.x.upstreams[0].route',
        'lowercase',
      ),
      (
        'an env key another record sets, in another case',
        '    x:\n${upstream('https://x.example')}      env:\n        NPM_CONFIG_REGISTRY: "{mirror}/x"\n',
        'container.registries.x.env.NPM_CONFIG_REGISTRY',
        'record "npm"',
      ),
      (
        'an env key that is not a POSIX name',
        '    x:\n${upstream('https://x.example')}      env:\n        "X-Y": z\n',
        'container.registries.x.env.X-Y',
        'POSIX',
      ),
      (
        'no upstreams',
        '    x:\n      env:\n        X_URL: "{mirror}/x"\n',
        'container.registries.x.upstreams',
        'upstream',
      ),
      (
        'an added record carrying only enabled: true',
        '    x:\n      enabled: true\n',
        'container.registries.x.upstreams',
        'upstream',
      ),
      (
        'a rewrite_json route the record does not define',
        '    x:\n${upstream('https://x.example')}      rewrite_json:\n'
            '        - route: other\n          path_prefix: /\n          content_types: [application/json]\n',
        'container.registries.x.rewrite_json[0].route',
        'not an upstream route',
      ),
      ('a record that is not a map', '    x: true\n', 'container.registries.x', 'must be a map'),
      (
        'enabled of the wrong type',
        '    npm:\n      enabled: "no"\n',
        'container.registries.npm.enabled',
        'true or false',
      ),
      (
        'upstreams of the wrong type',
        '    x:\n      upstreams: https://x.example\n',
        'container.registries.x.upstreams',
        'list',
      ),
      (
        'an origin of the wrong type',
        '    x:\n      upstreams:\n        - route: x\n          origin: 7\n',
        'container.registries.x.upstreams[0].origin',
        'string',
      ),
      (
        'a route of the wrong type',
        '    x:\n      upstreams:\n        - route: [x]\n          origin: https://x.example\n',
        'container.registries.x.upstreams[0].route',
        'string',
      ),
      (
        'env of the wrong type',
        '    x:\n${upstream('https://x.example')}      env: [A]\n',
        'container.registries.x.env',
        'map',
      ),
      (
        'an env value of the wrong type',
        '    x:\n${upstream('https://x.example')}      env:\n        X_URL: 3\n',
        'container.registries.x.env.X_URL',
        'string',
      ),
      (
        'rewrite_json of the wrong type',
        '    x:\n${upstream('https://x.example')}      rewrite_json: yes\n',
        'container.registries.x.rewrite_json',
        'list',
      ),
      (
        'content_types of the wrong type',
        '    x:\n${upstream('https://x.example')}      rewrite_json:\n'
            '        - route: x\n          path_prefix: /\n          content_types: application/json\n',
        'container.registries.x.rewrite_json[0].content_types',
        'list of strings',
      ),
      (
        'a field registries do not have',
        '    x:\n${upstream('https://x.example')}      headers: {}\n',
        'container.registries.x.headers',
        'not a registry record field',
      ),
      (
        'a record name that is not one lowercase segment',
        '    a b:\n${upstream('https://x.example')}',
        'container.registries.a b',
        'record name must be one segment',
      ),
      ('registries of the wrong type', '    - pub\n', 'container.registries', 'map of registry records'),
    ]) {
      test(label, () {
        expect(
          () => _load(yaml),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', allOf(contains(path), contains(rule)))),
        );
      });
    }

    test('a disabled record is held to type checks only', () {
      final records = _load('''
    x:
      enabled: false
      upstreams:
        - route: npm
          origin: http://10.0.0.1/path
      env:
        npm_config_registry: elsewhere
    y:
      enabled: false
''');
      expect(_named(records, 'x').enabled, isFalse);
      expect(_named(records, 'y').upstreams, isEmpty);
      expect(
        () => _load('    x:\n      enabled: false\n      upstreams:\n        - route: x\n          origin: 7\n'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('upstreams[0].origin'))),
      );
    });
  });
}
