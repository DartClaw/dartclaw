@Tags(['integration', 'slow'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:dartclaw_bridge/dartclaw_bridge.dart' show BridgeSurface;
import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, GuardBlockEvent;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../container/gateway/gateway_test_support.dart' show FakeBridgeChannel, builtInRegistryOn;
import '../runtime/harness_wiring_fixture.dart';
import 'container_integration_support.dart';

void main() {
  late String checkout;
  late String bridge;
  late Directory data;
  late HttpServer origin;
  late Map<String, List<int>> archives;
  late List<String> paths;
  const npmPackument = '{"dist":{"tarball":"https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz"}}';
  const dartImage = 'dartclaw-registry-dart-probe:latest';
  String recipeImage(String toolchain) => 'dartclaw-registry-$toolchain-probe:latest';
  late _Ecosystems ecosystems;

  setUpAll(() async {
    if (!await dockerAvailable()) throw StateError('Docker is required for registry bridge proof');
    checkout = await repoRoot();
    bridge = await ensureBridgeBinary(checkout);
    await ensureGatewayProbeImage();
    // The recipes and the cache directory build on the stock image of this checkout.
    final stock = await Process.run('docker', ['build', '-t', 'dartclaw-agent:latest', '$checkout/docker']);
    expect(stock.exitCode, 0, reason: '${stock.stdout}\n${stock.stderr}');
    for (final (toolchain, image) in [
      ('dart', dartImage),
      for (final toolchain in ['python', 'rust', 'go']) (toolchain, recipeImage(toolchain)),
    ]) {
      final built = await Process.run('docker', [
        'build',
        '-f',
        '$checkout/dev/testing/profiles/container/images/$toolchain.Dockerfile',
        '-t',
        image,
        '$checkout/dev/testing/profiles/container/images',
      ]);
      expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
    }
  });

  setUp(() async {
    data = Directory.systemTemp.createTempSync('registry-bridge-');
    archives = {};
    paths = [];
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      final rawPath = request.uri.toString();
      paths.add(rawPath);
      final bytes = archives[request.uri.path];
      if (bytes != null) {
        request.response.add(bytes);
      } else if (request.uri.path == '/api/packages/registry_fixture') {
        Map<String, Object?> version(String number) => {
          'version': number,
          'pubspec': {
            'name': 'registry_fixture',
            'version': number,
            'environment': {'sdk': '>=3.0.0 <4.0.0'},
          },
          'archive_url': 'http://127.0.0.1:${origin.port}/api/archives/registry_fixture-$number.tar.gz',
          'archive_sha256': sha256.convert(archives['/api/archives/registry_fixture-$number.tar.gz']!).toString(),
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'name': 'registry_fixture',
            'latest': version('1.1.0'),
            'versions': [version('1.0.0'), version('1.1.0')],
          }),
        );
      } else if (rawPath == '/is-odd' || rawPath.toLowerCase() == '/@scope%2fis') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(npmPackument);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    ecosystems = await _Ecosystems.start(data);
  });

  tearDown(() async {
    await origin.close(force: true);
    await ecosystems.close();
    data.deleteSync(recursive: true);
  });

  Future<ContainerAuthority> start({
    String profile = 'workspace',
    bool dart = false,
    String? image,
    String? project,
    bool volatile = false,
    List<({String authority, String ecosystem, String path, int status, bool served})>? audit,
  }) async {
    final upstream = Uri.parse('http://127.0.0.1:${origin.port}');
    final gateway = HostGateway(
      providerAdapters: {
        'claude': AnthropicMessagesAdapter(credential: ProviderCredentialSource.apiKey(() => 'unused')),
      },
      registries: [
        builtInRegistryOn('pub', {'pub': upstream}),
        builtInRegistryOn('npm', {'npm': upstream}),
        ...ecosystems.records,
      ],
      onRegistryRequest: (authority, ecosystem, path, status, served) async =>
          audit?.add((authority: authority, ecosystem: ecosystem, path: path, status: status, served: served)),
    );
    addTearDown(gateway.dispose);
    final principal = GatewayPrincipal(
      sessionId: 'registry-test',
      providerId: 'claude',
      policy: ExecutionPolicy.container(profile),
    );
    return startContainerAuthority(
      gateway: gateway,
      principal: principal,
      manager: ContainerManager(
        config: ContainerConfig(enabled: true, image: image ?? (dart ? dartImage : gatewayProbeImage)),
        ownerLabel: ContainerManager.ownerLabel(data.path),
        containerName: 'dartclaw-registry-${DateTime.now().microsecondsSinceEpoch}',
        profileId: profile,
        workspaceMounts: [
          if (profile == 'workspace')
            ...SecurityProfile.workspace(workspaceDir: null, projectDir: null).workspaceMounts,
          if (project != null) '$project:/project:rw',
        ],
        generatedStateDir: '${data.path}/state-${DateTime.now().microsecondsSinceEpoch}',
        volatileGeneratedState: volatile,
        registryClientEnvironment: gateway.registryClientEnvironment(principal),
        bridgeBinaryPath: bridge,
        buildContextDir: checkout,
        workingDir: project == null ? '/tmp' : '/project',
      ),
    );
  }

  test('workspace reads mirrored metadata and archive with network none; restricted has no path', () async {
    archives['/api/archives/registry_fixture-1.0.0.tar.gz'] = [1, 2, 255, 0];
    archives['/api/archives/registry_fixture-1.1.0.tar.gz'] = [42, 43, 0, 255];
    final workspace = await start();
    final metadata = await workspace.exec([
      'sh',
      '-c',
      r'curl -fsS --max-time 20 "$PUB_HOSTED_URL/api/packages/registry_fixture"',
    ]);
    expect(metadata.exitCode, 0, reason: metadata.stderr.toString());
    final decoded = jsonDecode(metadata.stdout as String) as Map<String, dynamic>;
    final archive = (decoded['latest'] as Map<String, dynamic>)['archive_url'] as String;
    expect(archive, 'http://127.0.0.1:8082/pub/api/archives/registry_fixture-1.1.0.tar.gz');
    final downloaded = await workspace.exec(['sh', '-c', 'curl -fsS --max-time 20 "$archive" | od -An -tu1']);
    expect(downloaded.exitCode, 0, reason: downloaded.stderr.toString());
    expect((downloaded.stdout as String).trim().split(RegExp(r'\s+')).map(int.parse), [42, 43, 0, 255]);
    expect(((await workspace.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
    final restricted = await start(profile: 'restricted');
    final environment = await restricted.exec(['env']);
    expect(environment.stdout.toString(), isNot(contains('PUB_HOSTED_URL=')));
    final refused = await restricted.exec(['curl', '-fsS', '--max-time', '5', archive]);
    expect(refused.exitCode, isNot(0));
    expect(((await restricted.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
  });

  test('pub get ignores a pub.dev lockfile and writes one naming the mirror', () async {
    for (final version in ['1.0.0', '1.1.0']) {
      final source = Directory('${data.path}/package-$version')..createSync();
      File('${source.path}/pubspec.yaml')
          .writeAsStringSync('name: registry_fixture\nversion: $version\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n');
      final archive = '${data.path}/package-$version.tar.gz';
      final packed = await Process.run('tar', ['-czf', archive, '-C', source.path, 'pubspec.yaml']);
      expect(packed.exitCode, 0, reason: packed.stderr.toString());
      archives['/api/archives/registry_fixture-$version.tar.gz'] = File(archive).readAsBytesSync();
    }
    final project = await createImageOwnedWorkspace('${data.path}/project');
    File('${project.path}/pubspec.yaml').writeAsStringSync(
      'name: mirror_consumer\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\ndependencies:\n  registry_fixture: ^1.0.0\n',
    );
    File('${project.path}/pubspec.lock').writeAsStringSync('''packages:
  registry_fixture:
    dependency: "direct main"
    description:
      name: registry_fixture
      sha256: ${sha256.convert(archives['/api/archives/registry_fixture-1.0.0.tar.gz']!)}
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
sdks:
  dart: ">=3.0.0 <4.0.0"
''');
    final authority = await start(dart: true, project: project.path);
    final installed = await authority.exec(['sh', '-c', 'cd /project && dart pub get']);
    expect(installed.exitCode, 0, reason: '${installed.stdout}\n${installed.stderr}');
    final lock = File('${project.path}/pubspec.lock').readAsStringSync();
    expect(lock, contains('url: "http://127.0.0.1:8082/pub/"'));
    expect(lock, contains('version: "1.1.0"'));
    expect(lock, isNot(contains('https://pub.dev')));
    expect(((await authority.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
  });

  test('npm workspace fetches unchanged packuments and a tarball; restricted has no registry', () async {
    archives['/is-odd/-/is-odd-3.0.1.tgz'] = [0, 42, 255, 43];
    final workspace = await start();
    for (final command in [
      r'curl -fsS --max-time 20 "${npm_config_registry}is-odd"',
      r'curl -fsS --max-time 20 "${npm_config_registry}@scope%2fis"',
    ]) {
      final metadata = await workspace.exec(['sh', '-c', command]);
      expect(metadata.exitCode, 0, reason: metadata.stderr.toString());
      expect(metadata.stdout, npmPackument);
    }
    final downloaded = await workspace.exec([
      'sh',
      '-c',
      r'curl -fsS --max-time 20 "${npm_config_registry}is-odd/-/is-odd-3.0.1.tgz" -o /tmp/npm.tgz && od -An -tu1 /tmp/npm.tgz',
    ]);
    expect(downloaded.exitCode, 0, reason: downloaded.stderr.toString());
    expect((downloaded.stdout as String).trim().split(RegExp(r'\s+')).map(int.parse), [0, 42, 255, 43]);
    expect(((await workspace.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');

    final restricted = await start(profile: 'restricted');
    final environment = await restricted.exec(['env']);
    expect(environment.exitCode, 0);
    expect(environment.stdout.toString(), isNot(contains('npm_config_registry=')));
    expect(environment.stdout.toString(), isNot(contains('npm_config_audit=')));
    final refused = await restricted.exec(['curl', '-fsS', '--max-time', '5', 'http://127.0.0.1:8082/npm/is-odd']);
    expect(refused.exitCode, isNot(0));
    expect(((await restricted.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
    expect(paths.map((path) => path.replaceAll('%2F', '%2f')), [
      '/is-odd',
      '/@scope%2fis',
      '/is-odd/-/is-odd-3.0.1.tgz',
    ]);
  });

  test('npm routed and transport refusals each emit one security wiring guard event', () async {
    final eventBus = EventBus();
    addTearDown(eventBus.dispose);
    final security = await wireTestSecurity(
      config: DartclawConfig(
        server: ServerConfig(dataDir: data.path),
        container: const ContainerConfig(enabled: true, image: gatewayProbeImage),
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'integration-key')}),
      ),
      dataDir: data.path,
      sourceCheckoutDir: checkout,
      eventBus: eventBus,
      exitFn: (code) => throw StateError('Unexpected exit($code) in registry wiring proof'),
    );
    addTearDown(security.dispose);
    final gateway = security.gateway!;
    final subject = GatewayPrincipal(
      sessionId: 'registry-event-test',
      providerId: 'claude',
      policy: ExecutionPolicy.container('workspace'),
    );
    final authority = gateway.register(principal: subject);
    final channel = FakeBridgeChannel();
    gateway.attach(authority, BridgeSurface.registry, channel);
    await channel.handshake(BridgeSurface.registry);
    final events = <GuardBlockEvent>[];
    final subscription = eventBus.on<GuardBlockEvent>().listen(events.add);
    addTearDown(subscription.cancel);

    for (final (id, method, path, status) in [
      (1, 'PUT', '/npm/is-odd', 405),
      (2, 'POST', '/npm/-/npm/v1/security/advisories/bulk', 405),
      (3, '', '/npm/is-odd', 400),
    ]) {
      final refusal = await channel.request(id, method: method, path: path);
      expect(refusal.status, status);
      expect(refusal.isDenied, isTrue);
    }
    await pumpEventQueue();
    const routed = ('host-gateway', 'bridge', 'registry: registry npm: only GET and HEAD are allowed');
    const transport = ('host-gateway', 'bridge', 'registry: request is missing a method or path');
    expect(events.map((event) => (event.guardName, event.hookPoint, event.verdictMessage)), [
      routed,
      routed,
      transport,
    ]);
  });

  test('pypi: pip and uv resolve and download through both pinned routes; restricted has neither', () async {
    final audit = <({String authority, String ecosystem, String path, int status, bool served})>[];
    final workspace = await start(image: recipeImage('python'), audit: audit);
    for (final command in [
      'pip download --no-deps --disable-pip-version-check -d /tmp/pip-dl fixture-pkg==1.0.0 && ls /tmp/pip-dl',
      'uv venv -q /tmp/venv && uv pip install -q --python /tmp/venv/bin/python fixture-pkg==1.0.0 && '
          '/tmp/venv/bin/python -c "import fixture_pkg; print(fixture_pkg.VALUE)"',
    ]) {
      final result = await workspace.exec(['sh', '-c', command]);
      expect(result.exitCode, 0, reason: '$command\n${result.stdout}\n${result.stderr}');
    }
    expect(((await workspace.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
    expect(ecosystems.pypiFiles.paths, everyElement('/packages/${_Ecosystems.wheelName}'));
    expect(ecosystems.pypiFiles.paths, isNotEmpty);
    expect(ecosystems.pypiIndex.paths, everyElement(startsWith('/simple/fixture-pkg')));
    final routes = {for (final entry in audit.where((entry) => entry.served)) entry.path.split('/')[1]};
    expect(routes, {'pypi', 'pypi-files'});
    expect(audit.every((entry) => entry.ecosystem == 'pypi' && entry.served), isTrue, reason: '$audit');
    await _expectNoRegistry(await start(profile: 'restricted', image: recipeImage('python')), [
      'PIP_INDEX_URL=',
      'UV_DEFAULT_INDEX=',
    ], '/pypi/simple/fixture-pkg/');
  });

  test(
    'crates: cargo fetch reads the sparse index and downloads through both routes; restricted has neither',
    () async {
      final audit = <({String authority, String ecosystem, String path, int status, bool served})>[];
      final workspace = await start(image: recipeImage('rust'), audit: audit);
      final fetched = await workspace.exec([
        'sh',
        '-c',
        'mkdir -p /tmp/consumer/src && cd /tmp/consumer && touch src/lib.rs && '
            'printf \'[package]\\nname = "consumer"\\nversion = "0.1.0"\\nedition = "2021"\\n\\n'
            '[dependencies]\\nfixture-crate = "1.0.0"\\n\' > Cargo.toml && cargo fetch && '
            'ls "\$CARGO_HOME"/registry/cache/*/fixture-crate-1.0.0.crate',
      ]);
      expect(fetched.exitCode, 0, reason: '${fetched.stdout}\n${fetched.stderr}');
      expect(((await workspace.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
      expect(ecosystems.cratesIndex.paths, containsAll(['/config.json', '/fi/xt/fixture-crate']));
      expect(ecosystems.cratesDownloads.paths, ['/crates/fixture-crate/1.0.0/download']);
      final routes = {for (final entry in audit.where((entry) => entry.served)) entry.path.split('/')[1]};
      expect(routes, {'crates', 'crates-dl'});
      await _expectNoRegistry(
        await start(profile: 'restricted', image: recipeImage('rust')),
        const [],
        '/crates/config.json',
      );
    },
  );

  test('go module: go mod download fetches from GOPROXY through the mirror; restricted has no route', () async {
    final audit = <({String authority, String ecosystem, String path, int status, bool served})>[];
    final workspace = await start(image: recipeImage('go'), audit: audit);
    final downloaded = await workspace.exec([
      'sh',
      '-c',
      'mkdir -p /tmp/consumer && cd /tmp/consumer && go mod init consumer && '
          'go mod download -json example.com/fixture@v1.0.0',
    ]);
    expect(downloaded.exitCode, 0, reason: '${downloaded.stdout}\n${downloaded.stderr}');
    expect(downloaded.stdout, contains('"Version": "v1.0.0"'));
    expect(((await workspace.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
    expect(ecosystems.goProxy.paths, containsAll(['/example.com/fixture/@v/v1.0.0.zip']));
    expect(audit.where((entry) => entry.served).map((entry) => entry.path), everyElement(startsWith('/go/')));
    await _expectNoRegistry(await start(profile: 'restricted', image: recipeImage('go')), [
      'GOPROXY=',
      'GOSUMDB=',
    ], '/go/example.com/fixture/@v/list');
  });

  test('package cache: workspace gets a writable executable volume removed with it; restricted does not', () async {
    for (final volatile in [false, true]) {
      final workspace = await start(image: 'dartclaw-agent:latest', volatile: volatile);
      final probe = await workspace.exec([
        'sh',
        '-c',
        'id -u && touch /var/cache/dartclaw/written && '
            'printf "#!/bin/sh\\necho executed\\n" > /var/cache/dartclaw/probe.sh && '
            'chmod +x /var/cache/dartclaw/probe.sh && /var/cache/dartclaw/probe.sh && '
            'cp /var/cache/dartclaw/probe.sh /tmp/probe.sh && ! /tmp/probe.sh',
      ]);
      expect(probe.exitCode, 0, reason: 'volatile=$volatile\n${probe.stdout}\n${probe.stderr}');
      expect((probe.stdout as String).split('\n'), containsAllInOrder(['1000', 'executed']));
      final mounts = ((await workspace.inspect())['Mounts'] as List).cast<Map<String, Object?>>();
      final cache = mounts.singleWhere((mount) => mount['Destination'] == SecurityProfile.packageCachePath);
      expect(cache['Type'], 'volume');
      final volume = cache['Name']! as String;
      expect((await Process.run('docker', ['volume', 'inspect', volume])).exitCode, 0);

      final restricted = await start(profile: 'restricted', image: 'dartclaw-agent:latest', volatile: volatile);
      final denied = await restricted.exec(['sh', '-c', 'touch /var/cache/dartclaw/written']);
      expect(denied.exitCode, isNot(0), reason: 'volatile=$volatile: restricted cache must not be writable');
      final restrictedMounts = ((await restricted.inspect())['Mounts'] as List).cast<Map<String, Object?>>();
      expect(restrictedMounts.where((mount) => mount['Destination'] == SecurityProfile.packageCachePath), isEmpty);

      await workspace.release();
      await restricted.release();
      var remains = true;
      for (var attempt = 0; attempt < 50 && remains; attempt++) {
        remains = (await Process.run('docker', ['volume', 'inspect', volume])).exitCode == 0;
        if (remains) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(remains, isFalse, reason: 'volatile=$volatile: volume $volume outlived its container');
    }
  });
}

Future<void> _expectNoRegistry(ContainerAuthority restricted, List<String> variables, String path) async {
  final environment = await restricted.exec(['env']);
  expect(environment.exitCode, 0);
  for (final variable in variables) {
    expect(environment.stdout.toString(), isNot(contains(variable)));
  }
  final refused = await restricted.exec(['curl', '-fsS', '--max-time', '5', 'http://127.0.0.1:8082$path']);
  expect(refused.exitCode, isNot(0));
  expect(((await restricted.inspect())['HostConfig'] as Map)['NetworkMode'], 'none');
}

/// A fake origin recording the paths it was asked for.
final class _Origin {
  new _(this.server);

  final HttpServer server;
  final List<String> paths = [];

  String get base => 'http://127.0.0.1:${server.port}';

  static Future<_Origin> serve(Future<void> Function(_Origin origin, HttpRequest request) handle) async {
    final origin = _Origin._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    origin.server.listen((request) async {
      origin.paths.add(request.uri.path);
      await handle(origin, request);
      await request.response.close();
    });
    return origin;
  }
}

/// Loopback fake origins for PyPI, crates.io and a Go module proxy, each
/// serving one package, and the records pinning them.
final class _Ecosystems {
  new _(this.pypiIndex, this.pypiFiles, this.cratesIndex, this.cratesDownloads, this.goProxy);

  static const wheelName = 'fixture_pkg-1.0.0-py3-none-any.whl';

  final _Origin pypiIndex;
  final _Origin pypiFiles;
  final _Origin cratesIndex;
  final _Origin cratesDownloads;
  final _Origin goProxy;

  List<RegistryRecord> get records => [
    builtInRegistryOn('pypi', {'pypi': Uri.parse(pypiIndex.base), 'pypi-files': Uri.parse(pypiFiles.base)}),
    builtInRegistryOn('crates', {'crates': Uri.parse(cratesIndex.base), 'crates-dl': Uri.parse(cratesDownloads.base)}),
    // The checksum database route is proven live; this case downloads only.
    RegistryRecord(
      name: 'go',
      upstreams: [RegistryUpstream(route: 'go', origin: goProxy.base)],
      env: const {'GOPROXY': '{mirror}/go', 'GOSUMDB': 'off', 'GOTOOLCHAIN': 'local'},
    ),
  ];

  static Future<_Ecosystems> start(Directory scratch) async {
    final wheel = _zip({
      'fixture_pkg/__init__.py': 'VALUE = "from-mirror"\n',
      'fixture_pkg-1.0.0.dist-info/METADATA': 'Metadata-Version: 2.1\nName: fixture-pkg\nVersion: 1.0.0\n',
      'fixture_pkg-1.0.0.dist-info/WHEEL':
          'Wheel-Version: 1.0\nGenerator: dartclaw-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
    }, record: 'fixture_pkg-1.0.0.dist-info/RECORD');
    final crate = await _crate(scratch);
    final goZip = _zip({
      'example.com/fixture@v1.0.0/go.mod': 'module example.com/fixture\n\ngo 1.21\n',
      'example.com/fixture@v1.0.0/fixture.go': 'package fixture\n\nconst Value = 42\n',
    });

    final pypiFiles = await _Origin.serve((origin, request) async {
      if (request.uri.path == '/packages/$wheelName') {
        request.response.add(wheel);
      } else {
        request.response.statusCode = 404;
      }
    });
    final pypiIndex = await _Origin.serve((origin, request) async {
      switch (request.uri.path) {
        case '/simple/fixture-pkg':
          request.response.statusCode = 301;
          request.response.headers.set('location', '/simple/fixture-pkg/');
        case '/simple/fixture-pkg/':
          request.response.headers.set('content-type', 'application/vnd.pypi.simple.v1+json');
          request.response.write(
            jsonEncode({
              'meta': {'api-version': '1.1'},
              'name': 'fixture-pkg',
              'versions': ['1.0.0'],
              'files': [
                {
                  'filename': wheelName,
                  'url': '${pypiFiles.base}/packages/$wheelName',
                  'hashes': {'sha256': sha256.convert(wheel).toString()},
                },
              ],
            }),
          );
        default:
          request.response.statusCode = 404;
      }
    });
    final cratesDownloads = await _Origin.serve((origin, request) async {
      if (request.uri.path == '/crates/fixture-crate/1.0.0/download') {
        request.response.add(crate);
      } else {
        request.response.statusCode = 404;
      }
    });
    final cratesIndex = await _Origin.serve((origin, request) async {
      switch (request.uri.path) {
        case '/config.json':
          request.response.headers.set('content-type', 'application/octet-stream');
          request.response.write(jsonEncode({'dl': '${cratesDownloads.base}/crates', 'api': 'https://crates.io'}));
        case '/fi/xt/fixture-crate':
          request.response.write(
            jsonEncode({
              'name': 'fixture-crate',
              'vers': '1.0.0',
              'deps': <Object?>[],
              'cksum': sha256.convert(crate).toString(),
              'features': <String, Object?>{},
              'yanked': false,
            }),
          );
        default:
          request.response.statusCode = 404;
      }
    });
    final goProxy = await _Origin.serve((origin, request) async {
      const module = '/example.com/fixture/@v/';
      switch (request.uri.path) {
        case '${module}list':
          request.response.write('v1.0.0\n');
        case '${module}v1.0.0.info':
          request.response.write(jsonEncode({'Version': 'v1.0.0', 'Time': '2026-01-01T00:00:00Z'}));
        case '${module}v1.0.0.mod':
          request.response.write('module example.com/fixture\n\ngo 1.21\n');
        case '${module}v1.0.0.zip':
          request.response.add(goZip);
        default:
          request.response.statusCode = 404;
      }
    });
    return _Ecosystems._(pypiIndex, pypiFiles, cratesIndex, cratesDownloads, goProxy);
  }

  Future<void> close() async {
    for (final origin in [pypiIndex, pypiFiles, cratesIndex, cratesDownloads, goProxy]) {
      await origin.server.close(force: true);
    }
  }

  static Future<List<int>> _crate(Directory scratch) async {
    final root = Directory(p.join(scratch.path, 'crate', 'fixture-crate-1.0.0', 'src'))..createSync(recursive: true);
    File(p.join(root.path, 'lib.rs')).writeAsStringSync('pub const VALUE: i32 = 42;\n');
    File(p.join(root.parent.path, 'Cargo.toml'))
        .writeAsStringSync('[package]\nname = "fixture-crate"\nversion = "1.0.0"\nedition = "2021"\n');
    final archive = p.join(scratch.path, 'fixture-crate-1.0.0.crate');
    final packed = await Process.run(
      'tar',
      ['-czf', archive, '-C', p.join(scratch.path, 'crate'), 'fixture-crate-1.0.0'],
      environment: {'COPYFILE_DISABLE': '1'},
    );
    expect(packed.exitCode, 0, reason: packed.stderr.toString());
    return File(archive).readAsBytesSync();
  }

  /// A stored (uncompressed) zip of [files]; [record] adds a wheel RECORD listing them.
  static List<int> _zip(Map<String, String> files, {String? record}) {
    final entries = {for (final entry in files.entries) entry.key: utf8.encode(entry.value)};
    if (record != null) {
      String digest(List<int> bytes) => base64Url.encode(sha256.convert(bytes).bytes).replaceAll('=', '');
      entries[record] = utf8.encode(
        [
          for (final entry in entries.entries) '${entry.key},sha256=${digest(entry.value)},${entry.value.length}',
          '$record,,',
        ].join('\n'),
      );
    }
    final out = BytesBuilder();
    final central = BytesBuilder();
    void u16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    void u32(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    for (final entry in entries.entries) {
      final name = utf8.encode(entry.key);
      final crc = _crc32(entry.value);
      final offset = out.length;
      for (final (builder, signature) in [(out, 0x04034b50), (central, 0x02014b50)]) {
        u32(builder, signature);
        if (builder == central) u16(builder, 20);
        for (final value in [20, 0, 0, 0, 0x21]) {
          u16(builder, value);
        }
        u32(builder, crc);
        u32(builder, entry.value.length);
        u32(builder, entry.value.length);
        u16(builder, name.length);
        u16(builder, 0);
        if (builder == central) {
          for (final value in [0, 0, 0]) {
            u16(builder, value);
          }
          u32(builder, 0);
          u32(builder, offset);
        }
        builder.add(name);
      }
      out.add(entry.value);
    }
    final centralOffset = out.length;
    final centralBytes = central.takeBytes();
    out.add(centralBytes);
    u32(out, 0x06054b50);
    for (final value in [0, 0, entries.length, entries.length]) {
      u16(out, value);
    }
    u32(out, centralBytes.length);
    u32(out, centralOffset);
    u16(out, 0);
    return out.takeBytes();
  }

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return crc ^ 0xffffffff;
  }
}
