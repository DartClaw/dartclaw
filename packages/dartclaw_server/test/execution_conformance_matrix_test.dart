import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'task/workflow_cli_runner_test_support.dart';

/// Release conformance matrix for the 0.24 execution boundary.
///
/// Every advertised provider/execution/surface combination is exercised here or
/// mapped to the fixture that observes it running; every other combination is a
/// required-denial path proven here. A combination with neither fails this
/// suite, so an advertised path can never lose its evidence silently.
///
/// Covers Acceptance Scenarios S01, S02, S04 and S06.
void main() {
  const providers = ['claude', 'codex', 'goose'];
  const acpProviders = {'goose'};
  const profiles = ['workspace', 'restricted'];

  final inventory = ProviderExecutionInventory.of(providerIds: providers, acpProviderIds: acpProviders);

  /// Registry of the fixtures that observe each combination this suite cannot
  /// exercise itself (they need a live container engine or a real subprocess).
  ///
  /// This is a *name* registry, not a second proof: it asserts the named test
  /// still exists, so deleting or renaming a fixture breaks the advertised
  /// combination it backs instead of quietly leaving it unproven. The behavior
  /// itself is proven by running those fixtures — see the dual-engine gate in
  /// `dev/guidelines/RELEASE_PREPARATION.md`.
  const runtimeEvidence = <String, (String, String)>{
    'claude/container/long-lived': (
      'test/integration/container_provider_parity_integration_test.dart',
      'a containerized process joins the container namespace, not the host',
    ),
    'codex/container/long-lived': (
      'test/integration/container_provider_parity_integration_test.dart',
      'both providers run inside the shipped image',
    ),
    'claude/host/workflow one-shot': (
      'test/task/workflow_cli_runner_test.dart',
      'builds Claude one-shot args and parses structured output',
    ),
    'codex/host/workflow one-shot': (
      'test/task/workflow_cli_runner_test.dart',
      'builds Codex one-shot args with explicit approval policy and sandbox override',
    ),
    'claude/container/workflow one-shot': (
      'test/task/workflow_cli_container_parity_test.dart',
      'claude runs the image binary, not the configured host path',
    ),
    'codex/container/workflow one-shot': (
      'test/task/workflow_cli_container_parity_test.dart',
      'codex runs the image binary, not the configured host path',
    ),
    'no host credential in a container': (
      'test/integration/container_provider_parity_integration_test.dart',
      'no host credential is readable from inside the container',
    ),
    'direct egress denial': (
      'test/integration/scoped_host_gateway_integration_test.dart',
      'a direct Internet probe from the container fails',
    ),
    'scoped host capability denial': (
      'test/integration/scoped_host_gateway_integration_test.dart',
      'an approved tool reaches the host implementation and an unapproved one does not',
    ),
    'cross-execution replay denial': (
      'test/integration/scoped_host_gateway_integration_test.dart',
      'concurrent authorities own separate containers and cannot borrow each other',
    ),
    'authority cleanup': (
      'test/integration/scoped_host_gateway_integration_test.dart',
      'release destroys the container, revokes the pipes, and is idempotent',
    ),
    'container startup failure': (
      'test/task/workflow_cli_container_parity_test.dart',
      'an unrunnable packaged CLI rejects before the turn is spawned',
    ),
    // Turn-level evidence. The rows above prove placement, denial, and
    // cleanup; these prove an agent can actually complete a provider turn
    // through mediation alone and write back into the mounted workspace.
    'mediated claude turn': (
      'test/integration/mediated_provider_turn_integration_test.dart',
      'a containerized claude turn writes into the mounted workspace through host mediation',
    ),
    'mediated codex turn': (
      'test/integration/mediated_codex_turn_integration_test.dart',
      'a containerized codex turn writes into the mounted workspace through its auth-clean home',
    ),
    'mediated turn upstream failure': (
      'test/integration/mediated_provider_turn_integration_test.dart',
      'an upstream failure mid-turn surfaces as a failed turn, never a silent success',
    ),
  };

  HarnessFactory factoryWithAcp() {
    final factory = HarnessFactory();
    factory.registerAcpAgent(
      'goose',
      const AcpAgentConfig(
        binary: 'goose',
        args: ['acp'],
        topology: AcpAgentTopology.direct,
        modelProvider: 'anthropic',
        verification: 'a0_1_goose_direct',
      ),
    );
    return factory;
  }

  group('advertised combinations run at their real boundary', () {
    for (final providerId in providers) {
      test('$providerId runs on the host with no container authority', () {
        final harness = factoryWithAcp().create(
          providerId,
          const HarnessFactoryConfig(cwd: '/tmp/workspace', executable: '/host/bin/provider'),
        );
        addTearDown(harness.dispose);

        // Placement is observed as the harness the factory really built: the
        // executable it will spawn on the host, and the absence of any
        // container authority to exec through. An ACP registration spawns its
        // configured binary; the built-ins spawn the resolved provider path.
        final (ContainerExecutor? container, String executable) = switch (harness) {
          ClaudeCodeHarness() => (harness.containerManager, harness.claudeExecutable),
          CodexHarness() => (harness.containerManager, harness.executable),
          AcpHarness() => (harness.containerManager, harness.executable),
          _ => fail('unexpected harness type for $providerId'),
        };

        expect(container, isNull);
        expect(executable, providerId == 'goose' ? 'goose' : '/host/bin/provider');
      });
    }

    for (final providerId in ['claude', 'codex']) {
      for (final profile in profiles) {
        test('$providerId keeps the container authority selected for $profile', () {
          final container = FakeContainerExecutor(hostRoot: '/host', containerRoot: '/workspace', profileId: profile);
          final harness = factoryWithAcp().create(
            providerId,
            HarnessFactoryConfig(cwd: '/tmp/workspace', containerManager: container),
          );
          addTearDown(harness.dispose);

          expect(
            switch (harness) {
              ClaudeCodeHarness() => harness.containerManager,
              CodexHarness() => harness.containerManager,
              _ => fail('unexpected harness type for $providerId'),
            },
            same(container),
            reason: 'a supplied authority is required, never an optimization the factory may drop',
          );
        });
      }
    }

    for (final providerId in ['claude', 'codex']) {
      test('$providerId has a workflow one-shot implementation', () {
        final runner = WorkflowCliRunner(providers: {providerId: WorkflowCliProviderConfig(executable: providerId)});

        expect(() => runner.maxTurnsForStructuredTurn(provider: providerId, noTools: true), returnsNormally);
      });
    }
  });

  group('required denials reject before any process or container exists', () {
    for (final profile in profiles) {
      test('an ACP provider is refused container/$profile on the long-lived surface', () {
        final verdict = inventory.verdictFor(
          providerId: 'goose',
          surface: ProviderLaunchSurface.longLived,
          policy: ExecutionPolicy.container(profile),
        );

        expect(verdict.reason, ProviderUnavailability.containerMediation);
        expect(verdict.message, contains('harness.acp.agents.goose'));
      });
    }

    test('an ACP harness refuses a container authority rather than dropping it', () {
      final container = FakeContainerExecutor(hostRoot: '/host', containerRoot: '/workspace');

      expect(
        () => factoryWithAcp().create(
          'goose',
          HarnessFactoryConfig(
            cwd: '/tmp/workspace',
            containerManager: container,
            environment: const {'ANTHROPIC_API_KEY': 'host-secret'},
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('was given a container manager'), isNot(contains('host-secret'))),
          ),
        ),
      );
    });

    test('an ACP provider named after a built-in family is not routed through that adapter', () {
      // Family resolution aliases an unknown provider onto claude/codex when
      // its ID or executable names one; the verdict is keyed by the configured
      // provider ID so that aliasing cannot manufacture support.
      var spawned = false;
      final runner = WorkflowCliRunner(
        providers: const {'claude-code-acp': WorkflowCliProviderConfig(executable: 'claude-code-acp')},
        executionInventory: ProviderExecutionInventory.of(
          providerIds: const ['claude-code-acp'],
          acpProviderIds: const {'claude-code-acp'},
        ),
        processStarter: (exe, args, {workingDirectory, environment}) async {
          spawned = true;
          throw StateError('an unavailable combination must never spawn a process');
        },
      );

      expect(
        () => runner.executeTurn(
          provider: 'claude-code-acp',
          prompt: 'work',
          workingDirectory: '/tmp',
          policy: const ExecutionPolicy.host(),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('"claude-code-acp" has no workflow one-shot launch implementation'),
          ),
        ),
      );
      expect(
        () => runner.maxTurnsForStructuredTurn(provider: 'claude-code-acp', noTools: true),
        throwsA(isA<UnsupportedError>()),
      );
      expect(spawned, isFalse);
    });

    for (final policy in [const ExecutionPolicy.host(), const ExecutionPolicy.container('workspace')]) {
      test('an ACP provider is refused the workflow one-shot surface as ${policy.describe()}', () {
        final runner = WorkflowCliRunner(
          providers: const {'goose': WorkflowCliProviderConfig(executable: 'goose')},
          executionInventory: inventory,
        );

        expect(
          () => runner.executeTurn(provider: 'goose', prompt: 'work', workingDirectory: '/tmp', policy: policy),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              contains('no workflow one-shot launch implementation'),
            ),
          ),
        );
      });
    }
  });

  group('both entry points consume one verdict', () {
    test('the workflow surface reports the verdict the inventory computes', () async {
      // No provider config either: the compatibility verdict must win over the
      // unconfigured-provider error, so both surfaces report the same reason.
      final runner = WorkflowCliRunner(providers: const {}, executionInventory: inventory);
      final expected = inventory.verdictFor(
        providerId: 'goose',
        surface: ProviderLaunchSurface.workflowOneShot,
        policy: const ExecutionPolicy.host(),
      );

      await expectLater(
        runner.executeTurn(
          provider: 'goose',
          prompt: 'work',
          workingDirectory: '/tmp',
          policy: const ExecutionPolicy.host(),
        ),
        throwsA(isA<UnsupportedError>().having((error) => error.message, 'message', expected.message)),
      );
    });

    test('workflow step compatibility rejects before container authority acquisition', () async {
      var acquired = false;
      final runner = WorkflowCliRunner(
        providers: const {'goose': WorkflowCliProviderConfig(executable: 'goose')},
        executionInventory: inventory,
        bridgedMcpToolsResolver: (_) => const {},
        containerAuthorities: (principal, {allowedMcpTools = const {}, artifactsDir}) async {
          acquired = true;
          throw StateError('unsupported compatibility must reject before acquisition');
        },
      );

      await expectLater(
        runner.leaseStepContainer(
          const ExecutionPolicy.container('workspace'),
          provider: 'goose',
          sessionId: 'session',
          taskId: 'task',
          allowedTools: null,
          artifactsDir: null,
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(acquired, isFalse);
    });

    test('a provider both surfaces implement is refused on neither', () {
      for (final providerId in ['claude', 'codex']) {
        for (final surface in ProviderLaunchSurface.values) {
          for (final policy in [
            const ExecutionPolicy.host(),
            for (final profile in profiles) ExecutionPolicy.container(profile),
          ]) {
            final verdict = inventory.verdictFor(providerId: providerId, surface: surface, policy: policy);
            expect(verdict.isSupported, isTrue, reason: verdict.message);
          }
        }
      }
    });
  });

  group('every advertised combination carries runtime evidence', () {
    late String packageRoot;

    setUpAll(() async {
      final libUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
      packageRoot = p.dirname(p.dirname(libUri!.toFilePath()));
    });

    test('the matrix names an observation for every advertised combination', () {
      // Derived from the inventory rather than restated, so narrowing or
      // widening a provider's support changes what this demands evidence for.
      final advertised = <String>{
        for (final providerId in providers)
          for (final surface in ProviderLaunchSurface.values)
            for (final policy in [const ExecutionPolicy.host(), const ExecutionPolicy.container('workspace')])
              if (inventory.verdictFor(providerId: providerId, surface: surface, policy: policy).isSupported)
                '$providerId/${policy.mode.name}/${surface.label}',
      };
      // Host long-lived placement is exercised in this suite; every remaining
      // advertised combination must name a fixture that observes it.
      final exercisedHere = {for (final providerId in providers) '$providerId/host/long-lived'};

      expect(advertised, contains('goose/host/long-lived'));
      expect(advertised, isNot(contains('goose/container/long-lived')));
      expect(advertised.difference(exercisedHere).difference(runtimeEvidence.keys.toSet()), isEmpty);
    });

    for (final entry in runtimeEvidence.entries) {
      test('${entry.key} is observed by ${entry.value.$2}', () {
        final file = File(p.join(packageRoot, entry.value.$1));

        expect(file.existsSync(), isTrue, reason: '${entry.value.$1} is missing');
        final source = file.readAsStringSync();

        expect(
          source,
          contains("test('${entry.value.$2}'"),
          reason: 'the fixture no longer declares a test observing this combination',
        );
        expect(source, isNot(contains('@Skip(')), reason: 'the fixture file is disabled wholesale');
      });
    }
  });
}
