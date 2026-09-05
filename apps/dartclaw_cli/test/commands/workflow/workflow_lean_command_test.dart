import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/server_reachability.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_resume_command.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';

void main() {
  for (final status in [200, 401, 403, 503]) {
    test('S03 health probe treats HTTP $status according to the safety contract', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.uri.path, '/health');
        request.response.statusCode = status;
        await request.response.close();
      });
      expect(await serverReachable(Uri.parse('http://127.0.0.1:${server.port}')), status != 503);
    });
  }

  for (final basePath in ['', '/', '/proxy', '/proxy/']) {
    test('S03 live-server guard preserves the health URL for "$basePath"', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final expectedPath = basePath.startsWith('/proxy') ? '/proxy/health' : '/health';
      server.listen((request) async {
        request.response.statusCode = request.uri.path == expectedPath ? 200 : 404;
        await request.response.close();
      });
      expect(await serverReachable(Uri.parse('http://127.0.0.1:${server.port}$basePath')), isTrue);
    });
  }

  for (final flags in [
    <String>[],
    ['--standalone'],
    ['--force'],
    ['--no-skill-bootstrap'],
  ]) {
    test('S02 lean run enters the standalone lane with $flags', () async {
      final config = DartclawConfig(server: const ServerConfig(port: 0));
      var reached = false;
      final command = WorkflowRunCommand(
        standaloneOnly: true,
        config: config,
        reachabilityProbe: (_) async {
          reached = true;
          throw const FakeExit(77);
        },
      );
      final runner = CommandRunner<void>('dartclaw-workflow', 'test')..addCommand(command);
      await expectLater(
        runner.run(['run', 'my-flow', ...flags]),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 77)),
      );
      expect(reached, isTrue);
      expect(command.usage, contains('script compatibility'));
    });
  }

  test('S02 lean resume accepts force without standalone', () async {
    var reached = false;
    final command = WorkflowResumeCommand(
      standaloneOnly: true,
      config: DartclawConfig(),
      reachabilityProbe: (_) async {
        reached = true;
        throw const FakeExit(77);
      },
    );
    final runner = CommandRunner<void>('dartclaw-workflow', 'test')..addCommand(command);
    await expectLater(runner.run(['resume', 'r1', '--force']), throwsA(isA<FakeExit>()));
    expect(reached, isTrue);
  });
}
