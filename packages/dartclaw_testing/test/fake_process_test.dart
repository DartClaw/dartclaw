import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeProcess', () {
    test('emits stdout and stderr lines and completes exit code', () async {
      final process = FakeProcess();

      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();

      process.emitStdout('stdout line');
      process.emitStderr('stderr line');
      process.exit(7);

      expect(await stdoutFuture, 'stdout line\n');
      expect(await stderrFuture, 'stderr line\n');
      expect(await process.exitCode, 7);
    });

    test('kill records the signal and can complete the process', () async {
      final process = FakeProcess(completeExitOnKill: true, killExitCode: 143);

      expect(process.kill(ProcessSignal.sigterm), isTrue);
      expect(process.killCalled, isTrue);
      expect(process.lastKillSignal, ProcessSignal.sigterm);
      expect(await process.exitCode, 143);
    });
  });

  group('CapturingFakeProcess', () {
    test('captures stdin lines and parsed JSONL maps', () async {
      final process = CapturingFakeProcess();

      process.stdin.add(utf8.encode('{"type":"control_response"}\n'));
      process.stdin.writeln('{"type":"tool_result","ok":true}');
      await process.stdin.close();

      expect(process.capturedStdinLines, ['{"type":"control_response"}', '{"type":"tool_result","ok":true}']);
      expect(process.capturedStdinJson, [
        {'type': 'control_response'},
        {'type': 'tool_result', 'ok': true},
      ]);
    });
  });
}
