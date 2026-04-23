import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowCliRunner Codex command', () {
    test('never emits --full-auto together with an explicit --sandbox', () {
      final cases = <({String? defaultSandbox, String? sandboxOverride, String? sandbox, bool fullAuto})>[
        (defaultSandbox: null, sandboxOverride: null, sandbox: null, fullAuto: true),
        (defaultSandbox: null, sandboxOverride: 'read-only', sandbox: 'read-only', fullAuto: false),
        (defaultSandbox: 'workspace-write', sandboxOverride: null, sandbox: 'workspace-write', fullAuto: false),
        (defaultSandbox: 'workspace-write', sandboxOverride: 'read-only', sandbox: 'read-only', fullAuto: false),
        (defaultSandbox: 'danger-full-access', sandboxOverride: 'read-only', sandbox: 'read-only', fullAuto: false),
      ];

      for (final fixture in cases) {
        final arguments = _buildArgs(defaultSandbox: fixture.defaultSandbox, sandboxOverride: fixture.sandboxOverride);

        expect(arguments.contains('--full-auto'), fixture.fullAuto, reason: '$fixture');
        final sandboxIndex = arguments.indexOf('--sandbox');
        if (fixture.sandbox == null) {
          expect(sandboxIndex, -1, reason: '$fixture');
        } else {
          expect(sandboxIndex, isNonNegative, reason: '$fixture');
          expect(arguments[sandboxIndex + 1], fixture.sandbox, reason: '$fixture');
        }
        expect(arguments.contains('--full-auto') && sandboxIndex != -1, isFalse, reason: '$fixture');
        if (fixture.defaultSandbox == 'danger-full-access' && fixture.sandboxOverride == 'read-only') {
          expect(arguments, isNot(contains('danger-full-access')));
        }
      }
    });
  });
}

List<String> _buildArgs({String? defaultSandbox, String? sandboxOverride}) {
  final runner = WorkflowCliRunner(
    providers: {
      'codex': WorkflowCliProviderConfig(executable: 'codex', options: {'sandbox': ?defaultSandbox}),
    },
  );
  final (_, arguments) = runner.buildCodexCommandForTesting(
    prompt: 'Inspect the repo',
    schemaDirectory: Directory.systemTemp.path,
    sandboxOverride: sandboxOverride,
  );
  return arguments;
}
