import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/connected_command_support.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../helpers/fake_api_transport.dart';
import '../helpers/fake_exit.dart';

void main() {
  group('resolveServerUri', () {
    test('defaults to loopback config port', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      final uri = resolveServerUri(config: config);
      expect(uri.toString(), 'http://localhost:4123');
    });

    test('accepts explicit remote server overrides', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      final uri = resolveServerUri(config: config, serverOverride: 'https://example.com:4000');
      expect(uri.toString(), 'https://example.com:4000');
    });

    test('keeps the remote default port when an explicit scheme override omits one', () {
      final config = DartclawConfig(server: ServerConfig(port: 4123));
      final uri = resolveServerUri(config: config, serverOverride: 'https://example.com');
      expect(uri.toString(), 'https://example.com');
      expect(uri.port, 443);
    });
  });

  group('apiClientFromConfig', () {
    test('request omits bearer token when auth mode is none', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'ok': true}),
        ],
      );
      final config = DartclawConfig(
        server: ServerConfig(dataDir: '/tmp/dartclaw-api-client-auth-none'),
        gateway: const GatewayConfig(authMode: 'none'),
      );
      final client = apiClientFromConfig(config: config, transport: transport);

      await client.getObject('/api/tasks');

      expect(transport.requests.single.headers.containsKey('authorization'), isFalse);
    });

    test('tokenOverride forces bearer auth even when local config auth_mode is none', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'ok': true}),
        ],
      );
      final config = DartclawConfig(
        server: ServerConfig(dataDir: '/tmp/dartclaw-api-client-remote-token'),
        gateway: const GatewayConfig(authMode: 'none'),
      );
      final client = apiClientFromConfig(config: config, tokenOverride: 'remote-token', transport: transport);

      await client.getObject('/api/tasks');

      expect(transport.requests.single.headers['authorization'], 'Bearer remote-token');
    });
  });

  group('exit codes:', () {
    for (final (code, status, expected) in <(String?, int?, int)>[
      ('CONNECTION_REFUSED', null, 3),
      ('NETWORK_ERROR', null, 3),
      ('TLS_HANDSHAKE_FAILED', null, 3),
      (null, 401, 4),
      (null, 403, 4),
      (null, 404, 5),
      (null, 409, 5),
      (null, 500, 6),
      ('INVALID_RESPONSE', 200, 1),
    ]) {
      test('$code / $status leaves stdout empty and maps failure', () async {
        final ApiTransport transport = status == null
            ? _FailingTransport(DartclawApiException('Transport failed.', code: code))
            : FakeApiTransport(
                sendResponses: [
                  jsonResponse(
                    status,
                    status == 200
                        ? []
                        : {
                            'error': {'code': 'FAILED', 'message': 'Request failed.'},
                          },
                  ),
                ],
              );
        final output = <String>[];
        final errors = <String>[];
        final runner = CommandRunner<void>('dartclaw', 'test')
          ..addCommand(
            _ProbeConnectedCommand(
              apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
              writeLine: output.add,
              stderrLine: errors.add,
              exitFn: fakeExit,
            ),
          );
        await expectLater(runner.run(['probe']), throwsA(isA<FakeExit>().having((e) => e.code, 'code', expected)));
        expect(output, isEmpty);
        expect(errors, hasLength(1));
        if (status == null) expect(errors.single, 'Transport failed.');
        if (status != null && status != 200 && status != 401) expect(errors.single, 'Request failed.');
        if (status == 200) expect(errors.single, 'Expected a JSON object from /api/tasks.');
      });
    }
  });

  group('ConnectedCommand error policy', () {
    test('a 401 prints the token remediation and exits 4 without echoing the token', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(401, {
            'error': {'code': 'AUTH_REQUIRED', 'message': 'Unauthorized'},
          }),
        ],
      );
      final output = <String>[];
      final errors = <String>[];
      final command = _ProbeConnectedCommand(
        apiClient: DartclawApiClient(
          baseUri: Uri.parse('http://localhost:3333'),
          token: 'secret-token',
          transport: transport,
        ),
        writeLine: output.add,
        stderrLine: errors.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(runner.run(['probe']), throwsA(isA<FakeExit>().having((exit) => exit.code, 'code', 4)));
      expect(output, isEmpty);
      expect(
        errors.single,
        allOf(
          contains('dartclaw token show'),
          contains('dartclaw token rotate'),
          contains('gateway.token'),
          contains('--token'),
          isNot(contains('secret-token')),
        ),
      );
    });
  });
}

class _ProbeConnectedCommand extends ConnectedCommand {
  new({required super.apiClient, required super.writeLine, required super.exitFn, required super.stderrLine});

  @override
  String get name => 'probe';

  @override
  String get description => 'Issues one request through the shared connected-command error policy.';

  @override
  Future<void> run() => runConnected((client) => client.getObject('/api/tasks'));
}

class _FailingTransport implements ApiTransport {
  final DartclawApiException error;
  new(this.error);
  @override
  Future<ApiResponse> send(ApiRequest request) async => throw error;
  @override
  Future<ApiResponse> openStream(ApiRequest request) async => throw error;
}
