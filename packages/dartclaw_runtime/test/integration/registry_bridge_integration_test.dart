@Tags(['integration', 'slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/container/gateway/pub_registry_adapter.dart';
import 'package:test/test.dart';

import 'container_integration_support.dart';

void main() {
  late String checkout;
  late String bridge;
  late Directory data;
  late HttpServer origin;
  late Map<String, List<int>> archives;
  const dartImage = 'dartclaw-registry-dart-probe:latest';

  setUpAll(() async {
    if (!await dockerAvailable()) throw StateError('Docker is required for registry bridge proof');
    checkout = await repoRoot();
    bridge = await ensureBridgeBinary(checkout);
    await ensureGatewayProbeImage();
    final built = await Process.run('docker', [
      'build',
      '-f',
      '$checkout/dev/testing/profiles/container/images/dart.Dockerfile',
      '-t',
      dartImage,
      checkout,
    ]);
    expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
  });

  setUp(() async {
    data = Directory.systemTemp.createTempSync('registry-bridge-');
    archives = {};
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
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
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await origin.close(force: true);
    data.deleteSync(recursive: true);
  });

  Future<ContainerAuthority> start({String profile = 'workspace', bool dart = false, String? project}) async {
    final gateway = HostGateway(
      providerAdapters: {
        'claude': AnthropicMessagesAdapter(credential: ProviderCredentialSource.apiKey(() => 'unused')),
      },
      registryAdapters: [PubRegistryAdapter(upstream: Uri.parse('http://127.0.0.1:${origin.port}'))],
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
        config: ContainerConfig(enabled: true, image: dart ? dartImage : gatewayProbeImage),
        ownerLabel: ContainerManager.ownerLabel(data.path),
        containerName: 'dartclaw-registry-${DateTime.now().microsecondsSinceEpoch}',
        profileId: profile,
        workspaceMounts: project == null ? const [] : ['$project:/project:rw'],
        generatedStateDir: '${data.path}/state',
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
}
