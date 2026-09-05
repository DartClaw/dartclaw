import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import '../helpers/fake_api_transport.dart';
import '../helpers/fake_exit.dart';

void main() {
  late StatusCommand statusCommand;

  setUp(() {
    statusCommand = StatusCommand();
  });

  group('StatusCommand', () {
    test('has no custom options', () {
      expect(statusCommand.argParser.options.keys, equals(['help']));
    });

    test('missing data directory prints informative message', () async {
      final output = <String>[];
      final globalDir = '${Directory.systemTemp.path}/dartclaw-status-missing-${DateTime.now().microsecondsSinceEpoch}';

      final config = DartclawConfig(server: ServerConfig(dataDir: globalDir));
      final command = StatusCommand(
        config: config,
        apiClient: _healthClient(),
        writeLine: output.add,
        exitFn: fakeExit,
        stderrLine: (line) => fail(line),
      );

      await command.run();
      expect(output, [
        'DartClaw Status',
        '  Server:    running at http://localhost:3333 (v$dartclawVersion, up 3h 12m)',
        '  Harness:   idle',
        'No data directory found at $globalDir',
      ]);
    });

    test('existing data directory prints session count and worker status line', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-test-');
      final sessionsDir = Directory('${tmp.path}/sessions');
      sessionsDir.createSync(recursive: true);

      // Create a session
      final sessions = SessionService(baseDir: sessionsDir.path);
      await sessions.createSession();

      addTearDown(() async {
        if (tmp.existsSync()) {
          await tmp.delete(recursive: true);
        }
      });

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tmp.path, claudeExecutable: '/usr/local/bin/claude'),
      );
      final command = StatusCommand(
        config: config,
        apiClient: _healthClient(),
        writeLine: output.add,
        exitFn: fakeExit,
        stderrLine: (line) => fail(line),
      );

      await command.run();

      expect(output, [
        'DartClaw Status',
        '  Server:    running at http://localhost:3333 (v$dartclawVersion, up 3h 12m)',
        '  Harness:   idle',
        '  Data dir:  ${tmp.path}',
        '  Sessions:  1',
        '  Memory:    unknown (no persisted collection status)',
        '  Index:     unknown',
      ]);
    });

    test('server and token overrides reach the health endpoint without loading config again', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      addTearDown(() => server.close(force: true));
      final requestHandled = server.first.then((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/health');
        expect(request.headers.value('authorization'), 'Bearer remote-token');
        request.response.write(
          jsonEncode({'status': 'healthy', 'uptime_s': 11520, 'worker_state': 'idle', 'version': dartclawVersion}),
        );
        await request.response.close();
      });
      final output = <String>[];
      final runner = CommandRunner<void>('dartclaw', 'test')
        ..argParser.addOption('server')
        ..argParser.addOption('token')
        ..addCommand(
          StatusCommand(
            config: DartclawConfig(
              server: ServerConfig(dataDir: '/nonexistent/dartclaw-status'),
              gateway: const GatewayConfig(authMode: 'none'),
            ),
            writeLine: output.add,
            stderrLine: (line) => fail(line),
            exitFn: fakeExit,
          ),
        );
      await runner.run(['--server', 'http://127.0.0.1:$port', '--token', 'remote-token', 'status']);
      await requestHandled;
      expect(output[1], '  Server:    running at http://127.0.0.1:$port (v$dartclawVersion, up 3h 12m)');
    });

    test('refused probe reports not running and retains local evidence', () async {
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-refused-');
      addTearDown(() => tmp.delete(recursive: true));
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      await SessionService(baseDir: config.sessionsDir).createSession();
      final output = <String>[];
      final errors = <String>[];
      await StatusCommand(
        config: config,
        apiClient: DartclawApiClient(
          baseUri: Uri.parse('http://localhost:3333'),
          transport: _FailedProbeTransport(DartclawApiException('Refused', code: 'CONNECTION_REFUSED')),
        ),
        writeLine: output.add,
        stderrLine: errors.add,
        exitFn: fakeExit,
      ).run();
      expect(output, [
        'DartClaw Status',
        '  Server:    not running at http://localhost:3333',
        '  Data dir:  ${tmp.path}',
        '  Sessions:  1',
        '  Memory:    unknown (no persisted collection status)',
        '  Index:     unknown',
      ]);
      expect(errors, isEmpty);
    });

    for (final (name, transport, message) in <(String, ApiTransport, String)>[
      (
        'TLS',
        _FailedProbeTransport(
          DartclawApiException(
            'TLS handshake failed for https://remote.example:4000: certificate',
            code: 'TLS_HANDSHAKE_FAILED',
          ),
        ),
        'TLS handshake failed for https://remote.example:4000: certificate',
      ),
      (
        '502',
        FakeApiTransport(
          sendResponses: [
            ApiResponse(statusCode: 502, headers: const {}, body: Stream.value(utf8.encode('Bad gateway'))),
          ],
        ),
        'The DartClaw server returned an internal error while handling /health.',
      ),
      (
        'non-200 success',
        FakeApiTransport(
          sendResponses: [
            jsonResponse(201, {
              'status': 'healthy',
              'uptime_s': 11520,
              'worker_state': 'idle',
              'version': dartclawVersion,
            }),
          ],
        ),
        'Expected HTTP 200 from /health, received HTTP 201.',
      ),
      (
        'malformed JSON',
        FakeApiTransport(
          sendResponses: [
            ApiResponse(statusCode: 200, headers: const {}, body: Stream.value(utf8.encode('<html>proxy</html>'))),
          ],
        ),
        'Unexpected character',
      ),
      (
        'malformed error code',
        FakeApiTransport(
          sendResponses: [
            jsonResponse(502, {
              'error': {'code': 123, 'message': 'proxy failure'},
            }),
          ],
        ),
        'Invalid error response from /health.',
      ),
      (
        'malformed error message',
        FakeApiTransport(
          sendResponses: [
            jsonResponse(502, {
              'error': {'code': 'PROXY_ERROR', 'message': []},
            }),
          ],
        ),
        'Invalid error response from /health.',
      ),
      (
        'HTTP refusal code collision',
        FakeApiTransport(
          sendResponses: [
            jsonResponse(502, {
              'error': {'code': 'CONNECTION_REFUSED', 'message': 'upstream refused'},
            }),
          ],
        ),
        'upstream refused',
      ),
      ('non-object', FakeApiTransport(sendResponses: [jsonResponse(200, [])]), 'Expected a JSON object from /health.'),
      (
        'missing fields',
        FakeApiTransport(sendResponses: [jsonResponse(200, {})]),
        'Invalid health response from /health.',
      ),
    ]) {
      test('$name probe failure reports unreachable with its origin and message', () async {
        final tmp = await Directory.systemTemp.createTemp('dartclaw-status-failed-probe-');
        addTearDown(() => tmp.delete(recursive: true));
        final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
        await SessionService(baseDir: config.sessionsDir).createSession();
        final output = <String>[];
        final runner = CommandRunner<void>('dartclaw', 'test')
          ..argParser.addOption('server')
          ..addCommand(
            StatusCommand(
              config: config,
              apiClient: DartclawApiClient(baseUri: Uri.parse('https://remote.example:4000'), transport: transport),
              writeLine: output.add,
              stderrLine: (line) => fail(line),
              exitFn: fakeExit,
            ),
          );
        await runner.run(['--server', 'https://remote.example:4000', 'status']);
        expect(output, [
          'DartClaw Status',
          '  Server:    unreachable at https://remote.example:4000: $message',
          '  Data dir:  ${tmp.path}',
          '  Sessions:  1',
          '  Memory:    unknown (no persisted collection status)',
          '  Index:     unknown',
        ]);
      });
    }

    test('dropped HTTP exchange reports unreachable and retains local evidence', () async {
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-dropped-');
      addTearDown(() => tmp.delete(recursive: true));
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      await SessionService(baseDir: config.sessionsDir).createSession();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      });
      final output = <String>[];
      await StatusCommand(
        config: config,
        apiClient: DartclawApiClient(baseUri: Uri.parse(origin)),
        writeLine: output.add,
        stderrLine: (line) => fail(line),
        exitFn: fakeExit,
      ).run();
      expect(output[1], startsWith('  Server:    unreachable at $origin: Connection closed'));
      expect(output.skip(2), [
        '  Data dir:  ${tmp.path}',
        '  Sessions:  1',
        '  Memory:    unknown (no persisted collection status)',
        '  Index:     unknown',
      ]);
    });

    for (final version in [dartclawVersion, '0.0.0-other']) {
      test('health version $version renders mismatch only when needed and probes once', () async {
        final transport = FakeApiTransport(
          sendResponses: [
            jsonResponse(200, {'status': 'healthy', 'uptime_s': 11520, 'worker_state': 'idle', 'version': version}),
          ],
        );
        final output = <String>[];
        await StatusCommand(
          config: DartclawConfig(server: ServerConfig(dataDir: '/nonexistent/dartclaw-status')),
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
          writeLine: output.add,
          stderrLine: (line) => fail(line),
          exitFn: fakeExit,
        ).run();
        final mismatch = version == dartclawVersion ? '' : '; CLI is v$dartclawVersion';
        expect(output[1], '  Server:    running at http://localhost:3333 (v$version, up 3h 12m$mismatch)');
        expect(transport.requests.single.method, 'GET');
        expect(transport.requests.single.uri.path, '/health');
      });
    }

    test('reads persisted committed corpus and degraded index while server is stopped', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-memory-test-');
      addTearDown(() async => tmp.delete(recursive: true));
      Directory('${tmp.path}/sessions').createSync(recursive: true);
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      final corpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
      final snapshot = await corpus.statusSnapshot();
      await corpus.close();
      final sidecar = File('${config.workspaceDir}/.dartclaw-memory-corpus.json');
      final persisted = jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
      final status = persisted['status'] as Map<String, dynamic>;
      status
        ..['observationOldest'] = '2026-08-01T00:00:00.000Z'
        ..['observationNewest'] = '2026-08-12T00:00:00.000Z'
        ..['opaqueLegacyLocators'] = ['memory/legacy/<opaque>']
        ..['migrationState'] = 'migrated'
        ..['migrationSnapshotPath'] = '/workspace/<snapshot>'
        ..['migrationAction'] = 'Inspect <snapshot> before removal.';
      sidecar.writeAsStringSync(jsonEncode(persisted));
      await IndexHealthStore(workspaceDir: config.workspaceDir).recordDegraded(
        canonicalRevision: snapshot.collectionRevision,
        canonicalFingerprint: snapshot.collectionFingerprint,
        stage: 'validation',
        reason: 'test failure',
      );

      await StatusCommand(
        config: config,
        apiClient: _healthClient(),
        writeLine: output.add,
        exitFn: fakeExit,
        stderrLine: (line) => fail(line),
      ).run();

      expect(output, contains(contains('Memory:    revision 1; curated=0')));
      expect(output, contains('  Observation usage: 0 bytes (exact); warning=none'));
      expect(output, contains(contains('Observation range: 2026-08-01')));
      expect(output, contains('  Migration: migrated; snapshot=/workspace/<snapshot>'));
      expect(output, contains('  Migration action: Inspect <snapshot> before removal.'));
      expect(output, contains('  Opaque legacy: 1; memory/legacy/<opaque>'));
      expect(output, contains(contains('Index:     degraded; canonical=1; indexed=unknown')));
      expect(output, contains('  Index failure stage: validation'));
      expect(output, contains('  Index reason: test failure'));
      expect(output, contains(contains('stop DartClaw')));
    });

    test('corrupt persisted collection evidence fails closed without scanning the workspace', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-corrupt-test-');
      addTearDown(() async => tmp.delete(recursive: true));
      Directory('${tmp.path}/sessions').createSync(recursive: true);
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      Directory(config.workspaceDir).createSync(recursive: true);
      File('${config.workspaceDir}/.dartclaw-memory-corpus.json').writeAsStringSync('{broken');
      File('${config.workspaceDir}/MEMORY.md').writeAsStringSync('## tempting fallback\n- [2026-08-12] do not scan');

      await StatusCommand(
        config: config,
        apiClient: _healthClient(),
        writeLine: output.add,
        exitFn: fakeExit,
        stderrLine: (line) => fail(line),
      ).run();

      expect(output, contains('  Memory:    unknown (persisted evidence could not be read)'));
      expect(output, contains('  Index:     unknown'));
      expect(output.join('\n'), isNot(contains('tempting fallback')));
    });

    test('corrupt index evidence does not invalidate a valid persisted corpus', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-corrupt-index-test-');
      addTearDown(() async => tmp.delete(recursive: true));
      Directory('${tmp.path}/sessions').createSync(recursive: true);
      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path));
      final corpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
      await corpus.statusSnapshot();
      await corpus.close();
      File('${config.workspaceDir}/.dartclaw-memory-index.json').writeAsStringSync('{broken');

      await StatusCommand(
        config: config,
        apiClient: _healthClient(),
        writeLine: output.add,
        exitFn: fakeExit,
        stderrLine: (line) => fail(line),
      ).run();

      expect(output, contains(contains('Memory:    revision 1; curated=0')));
      expect(output, isNot(contains('  Memory:    unknown (persisted evidence could not be read)')));
      expect(output, contains('  Index:     unknown'));
      expect(output, contains(contains('stop DartClaw')));
    });
  });
}

DartclawApiClient _healthClient() => DartclawApiClient(
  baseUri: Uri.parse('http://localhost:3333'),
  transport: FakeApiTransport(
    sendResponses: [
      jsonResponse(200, {'status': 'healthy', 'uptime_s': 11520, 'worker_state': 'idle', 'version': dartclawVersion}),
    ],
  ),
);

class _FailedProbeTransport implements ApiTransport {
  final DartclawApiException error;
  new(this.error);
  @override
  Future<ApiResponse> send(ApiRequest request) async => throw error;
  @override
  Future<ApiResponse> openStream(ApiRequest request) => throw StateError('No stream expected');
}
