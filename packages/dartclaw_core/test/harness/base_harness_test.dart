import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/base_harness.dart';
import 'package:dartclaw_core/src/harness/claude_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/codex_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/protocol_adapter.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

final class _LineRecordingHarness extends BaseHarness {
  _LineRecordingHarness(this.adapter)
    : super(
        log: Logger.detached('base-harness-crlf-test'),
        cwd: '/tmp',
        turnTimeout: const Duration(seconds: 1),
        maxRetries: 0,
        baseBackoff: Duration.zero,
        processFactory: Process.start,
        commandProbe: Process.run,
        delayFactory: Future<void>.delayed,
        harnessConfig: const HarnessConfig(),
      );

  final ProtocolAdapter adapter;
  final parsed = <Object?>[];
  final rawLines = <String>[];

  void attach(Process process) => attachProcess(process, dropEmptyStdoutLines: true, watchForUnexpectedExit: false);

  @override
  void handleProcessStdoutLine(String line) {
    rawLines.add(line);
    parsed.add(adapter.parseLine(line));
  }

  @override
  void handleUnexpectedProcessExit(int exitCode) {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async => const <String, dynamic>{};
}

void main() {
  test('shared provider stream parsing tolerates CRLF and split CRLF chunks', () async {
    final cases = <({ProtocolAdapter adapter, Map<String, dynamic> line})>[
      (adapter: ClaudeProtocolAdapter(), line: {'type': 'result', 'stop_reason': 'end_turn', 'is_error': false}),
      (
        adapter: CodexProtocolAdapter(),
        line: {
          'method': 'turn/completed',
          'params': {'usage': <String, dynamic>{}},
        },
      ),
    ];

    for (final testCase in cases) {
      final stdoutController = StreamController<List<int>>();
      final process = FakeProcess(stdoutController: stdoutController);
      final harness = _LineRecordingHarness(testCase.adapter)..attach(process);
      addTearDown(harness.dispose);
      final encoded = utf8.encode(jsonEncode(testCase.line));

      stdoutController.add([...encoded, 13]);
      stdoutController.add([10, 13, 10]);
      await pumpEventQueue();

      expect(harness.rawLines, [jsonEncode(testCase.line)]);
      expect(harness.rawLines.single, isNot(contains('\r')));
      expect(harness.parsed.single, isNotNull);
      await stdoutController.close();
    }
  });
}
