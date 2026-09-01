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

      await client.get('/api/tasks');

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

      await client.get('/api/tasks');

      expect(transport.requests.single.headers['authorization'], 'Bearer remote-token');
    });
  });

  group('ConnectedCommand error policy', () {
    test('a 401 prints the token remediation and exits 1 without echoing the token', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(401, {
            'error': {'code': 'AUTH_REQUIRED', 'message': 'Unauthorized'},
          }),
        ],
      );
      final output = <String>[];
      final command = _ProbeConnectedCommand(
        apiClient: DartclawApiClient(
          baseUri: Uri.parse('http://localhost:3333'),
          token: 'secret-token',
          transport: transport,
        ),
        writeLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(runner.run(['probe']), throwsA(isA<FakeExit>().having((exit) => exit.code, 'code', 1)));
      expect(
        output.single,
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
  new({required super.apiClient, required super.writeLine, required super.exitFn});

  @override
  String get name => 'probe';

  @override
  String get description => 'Issues one request through the shared connected-command error policy.';

  @override
  Future<void> run() => runConnected((client) => client.get('/api/tasks'));
}
