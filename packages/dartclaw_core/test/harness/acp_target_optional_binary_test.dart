import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP target optional binary validation', () {
    test('isolates missing optional binaries without implicit install attempts', () async {
      const validator = AcpTargetValidator();
      final calls = <String>[];
      const agents = {
        'goose': AcpAgentConfig(
          binary: 'goose',
          args: ['acp', '--with-builtin', 'developer'],
          topology: AcpAgentTopology.direct,
          modelProvider: 'anthropic',
          verification: 'a0_1_goose_direct',
          requiresGuardMediation: true,
          requiredBuiltins: ['developer'],
        ),
        'vibe': AcpAgentConfig(
          binary: 'vibe-acp',
          topology: AcpAgentTopology.direct,
          modelProvider: 'mistral',
          verification: 'vibe_acp_direct_probe',
          requiresGuardMediation: true,
        ),
      };

      final missingVibe = await validator.validateConfiguredTargets(
        agents: agents,
        targetProbe: _guardMediatedProbe,
        advertisedCapabilities: const {
          'vibe': {'fs', 'terminal'},
        },
        commandProbe: (executable, arguments) async {
          calls.add(executable);
          if (executable == 'vibe-acp') throw const ProcessException('vibe-acp', ['--version'], 'missing');
          return ProcessResult(1, 0, 'goose 1.0.0', '');
        },
      );

      expect(missingVibe['goose']!.isGuardMediated, isTrue);
      expect(missingVibe['vibe']!.errorCode, 'SPAWN_FAILED');
      expect(missingVibe['vibe']!.status.id, 'skipped');

      final requiredMissingGoose = await validator.validateConfiguredTargets(
        agents: agents,
        requiredTargets: {'goose'},
        targetProbe: _guardMediatedProbe,
        advertisedCapabilities: const {
          'vibe': {'fs', 'terminal'},
        },
        commandProbe: (executable, arguments) async {
          calls.add(executable);
          if (executable == 'goose') throw const ProcessException('goose', ['--version'], 'missing');
          return ProcessResult(2, 0, 'vibe 1.0.0', '');
        },
      );

      expect(requiredMissingGoose['goose']!.errorCode, 'SPAWN_FAILED');
      expect(requiredMissingGoose['goose']!.status.id, 'failed');
      expect(requiredMissingGoose['vibe']!.isGuardMediated, isTrue);
      expect(calls, isNot(contains(anyOf('brew', 'curl', 'npm', 'dart'))));
    });
  });
}

Future<Iterable<AcpTargetOperationEvidence>> _guardMediatedProbe(String providerId, AcpAgentConfig config) async {
  return guardMediatedTargetEvidence();
}
