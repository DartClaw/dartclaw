import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

/// A runtime probe that answers only for the binaries in [available].
RunCommand _probe(Set<String> available, {List<String>? seen}) => (executable, arguments) async {
  seen?.add('$executable ${arguments.join(' ')}');
  if (!available.contains(executable)) throw ProcessException(executable, arguments, 'No such file or directory', 2);
  return ProcessResult(0, 0, '', '');
};

void main() {
  final posix = PlatformCapabilities(operatingSystem: 'linux');

  group('an undeclared posture is settled by probing', () {
    test('a host with a runtime isolates without the operator writing a container section', () async {
      final resolved = await resolveContainerPosture(
        const DartclawConfig(),
        platformCapabilities: posix,
        runCommand: _probe({'docker'}),
      );

      expect(resolved.container.enabled, isTrue);
      expect(resolved.container.runtimeBinary, 'docker');
      expect(
        resolved.container.declaredEnabled,
        isNull,
        reason: 'the operator declared nothing and still declares nothing',
      );
    });

    // A wedged daemon never returns rather than erroring, and this probe runs
    // before serve binds a port — the posture exists to downgrade instead of
    // blocking startup, so a hang has to be a downgrade too.
    test('a runtime that never answers is a downgrade, not a hung startup', () async {
      final resolved = await resolveContainerPosture(
        const DartclawConfig(),
        platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
        runCommand: (_, _) => Completer<ProcessResult>().future,
      ).timeout(const Duration(seconds: 30));

      expect(resolved.container.enabled, isFalse);
    });

    test('a host with no runtime resolves to advisory mode rather than failing', () async {
      final resolved = await resolveContainerPosture(
        const DartclawConfig(),
        platformCapabilities: posix,
        runCommand: _probe(const {}),
      );

      expect(resolved.container.enabled, isFalse);
    });

    test('a host carrying only the second supported runtime is still isolatable', () async {
      final seen = <String>[];
      final resolved = await resolveContainerPosture(
        const DartclawConfig(),
        platformCapabilities: posix,
        runCommand: _probe({'podman'}, seen: seen),
      );

      expect(resolved.container.enabled, isTrue);
      expect(resolved.container.runtimeBinary, 'podman');
      expect(seen, ['docker version', 'podman version']);
    });

    test('the resolved binary is the one every subsequent runtime call uses', () async {
      final resolved = await resolveContainerPosture(
        const DartclawConfig(),
        platformCapabilities: posix,
        runCommand: _probe({'podman'}),
      );
      final calls = <String>[];
      final manager = ContainerManager(
        config: resolved.container,
        containerName: 'dartclaw-test',
        profileId: 'restricted',
        workspaceMounts: const [],
        generatedStateDir: '/tmp/dartclaw-test',
        runCommand: _probe({'podman'}, seen: calls),
      );

      await manager.isRuntimeAvailable();

      expect(calls, ['podman version']);
    });

    test('native Windows is never probed, let alone auto-enabled', () async {
      final seen = <String>[];
      final resolved = await resolveContainerPosture(
        const DartclawConfig(),
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        runCommand: _probe({'docker'}, seen: seen),
      );

      expect(resolved.container.enabled, isFalse);
      expect(seen, isEmpty, reason: 'the platform gate precedes any runtime detection');
    });
  });

  group('a declared posture is never overridden', () {
    test('an explicit false stays disabled with a runtime present, and costs no probe', () async {
      final seen = <String>[];
      final resolved = await resolveContainerPosture(
        const DartclawConfig(container: ContainerConfig(enabled: false)),
        platformCapabilities: posix,
        runCommand: _probe({'docker'}, seen: seen),
      );

      expect(resolved.container.enabled, isFalse);
      expect(seen, isEmpty);
    });

    test('an explicit true survives a host with no runtime, so wiring can refuse it', () async {
      final resolved = await resolveContainerPosture(
        const DartclawConfig(container: ContainerConfig(enabled: true)),
        platformCapabilities: posix,
        runCommand: _probe(const {}),
      );

      expect(resolved.container.enabled, isTrue);
      expect(resolved.container.declaredEnabled, isTrue);
      expect(resolved.container.runtimeBinary, 'docker', reason: 'the refusal must name the runtime it looked for');
    });
  });

  group('cross-section execution policy is evaluated against the resolved posture', () {
    test('an explicit container execution mode is rejected when detection found no runtime', () async {
      await expectLater(
        resolveContainerPosture(
          const DartclawConfig(
            agent: AgentConfig(provider: 'claude', execution: ExecutionMode.container),
          ),
          platformCapabilities: posix,
          runCommand: _probe(const {}),
        ),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('agent.execution'))),
      );
    });

    test('the same selection passes once detection resolved the posture to enabled', () async {
      final resolved = await resolveContainerPosture(
        const DartclawConfig(
          agent: AgentConfig(provider: 'claude', execution: ExecutionMode.container),
        ),
        platformCapabilities: posix,
        runCommand: _probe({'docker'}),
      );

      expect(resolved.container.enabled, isTrue);
    });
  });
}
