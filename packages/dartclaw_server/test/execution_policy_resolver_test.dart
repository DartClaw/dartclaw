import 'package:dartclaw_core/dartclaw_core.dart' show ProviderExecutionInventory;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

/// Precedence, default, and fail-closed matrix for the one resolution
/// authority shared by every execution entry point.
///
/// Covers Acceptance Scenarios S01, S02 and S05.
void main() {
  const workspaceAndRestricted = {'workspace', 'restricted'};

  ExecutionPolicyResolver resolverFor({
    bool containersEnabled = true,
    ExecutionMode? primary,
    List<AgentDefinition> agents = const [],
    Map<TaskType, ExecutionMode> taskExecution = const {},
    Set<String>? availableProfiles,
  }) => ExecutionPolicyResolver(
    config: DartclawConfig.defaults().copyWith(
      container: ContainerConfig(enabled: containersEnabled),
      agent: AgentConfig(execution: primary, definitions: agents),
      tasks: TaskConfig(execution: taskExecution),
    ),
    availableContainerProfiles: availableProfiles ?? (containersEnabled ? workspaceAndRestricted : const {}),
  );

  const ordinaryAgent = AgentDefinition(id: 'coder', description: 'writes code', prompt: 'code');
  const searchAgent = AgentDefinition(
    id: 'search',
    description: 'searches',
    prompt: 'search',
    securityProfile: 'restricted',
  );

  group('S01 unchanged configurations preserve the current boundary', () {
    test('containers enabled: every omitted setting resolves to container execution', () {
      final resolver = resolverFor(agents: const [ordinaryAgent, searchAgent]);

      expect(resolver.resolveForPrimary(providerId: 'claude'), const ExecutionPolicy.container('workspace'));
      expect(
        resolver.resolveForAgent(ordinaryAgent, providerId: 'claude'),
        const ExecutionPolicy.container('workspace'),
      );
      expect(
        resolver.resolveForAgent(searchAgent, providerId: 'claude'),
        const ExecutionPolicy.container('restricted'),
        reason: 'the built-in search profile default is unchanged',
      );
      expect(resolver.resolveForTaskType(TaskType.coding), const ExecutionPolicy.container('workspace'));
      expect(resolver.resolveForTaskType(TaskType.research), const ExecutionPolicy.container('restricted'));
      expect(resolver.deploymentDefault, const ExecutionPolicy.container('workspace'));
    });

    test('containers disabled: neutral-profile contexts resolve to host with no profile', () {
      final resolver = resolverFor(containersEnabled: false, agents: const [ordinaryAgent]);

      expect(resolver.resolveForPrimary(providerId: 'claude'), const ExecutionPolicy.host());
      expect(resolver.resolveForAgent(ordinaryAgent, providerId: 'claude'), const ExecutionPolicy.host());
      expect(resolver.resolveForTaskType(TaskType.coding), const ExecutionPolicy.host());
      expect(resolver.deploymentDefault, const ExecutionPolicy.host());
    });

    test('containers disabled: a container-only default profile fails closed rather than degrading to host', () {
      final resolver = resolverFor(containersEnabled: false, agents: const [searchAgent]);

      expect(
        () => resolver.resolveForAgent(searchAgent, providerId: 'claude'),
        throwsA(
          isA<ExecutionPolicyException>().having(
            (error) => error.message,
            'message',
            allOf(contains('search'), contains('restricted'), contains('agent.agents.search.execution: host')),
          ),
        ),
      );
      expect(
        () => resolver.resolveForTaskType(TaskType.research),
        throwsA(
          isA<ExecutionPolicyException>().having(
            (error) => error.message,
            'message',
            allOf(contains('research'), contains('tasks.execution.research: host')),
          ),
        ),
      );
    });

    test('an explicit host selection legitimately drops the mode-conditional profile default', () {
      const explicitHostSearch = AgentDefinition(
        id: 'search',
        description: 'searches',
        prompt: 'search',
        securityProfile: 'restricted',
        execution: ExecutionMode.host,
      );
      final resolver = resolverFor(containersEnabled: false, agents: const [explicitHostSearch]);

      expect(resolver.resolveForAgent(explicitHostSearch, providerId: 'claude'), const ExecutionPolicy.host());
      expect(
        resolverFor(
          containersEnabled: false,
          taskExecution: const {TaskType.research: ExecutionMode.host},
        ).resolveForTaskType(TaskType.research),
        const ExecutionPolicy.host(),
      );
    });
  });

  group('S01 an inherited host mode never discards a configured profile', () {
    const configuredRestricted = AgentDefinition(
      id: 'search',
      description: 'searches',
      prompt: 'search',
      securityProfile: 'restricted',
      profileIsOperatorConfigured: true,
    );

    for (final containersEnabled in [true, false]) {
      test(
        'agent.execution: host is rejected for it with containers ${containersEnabled ? 'enabled' : 'disabled'}',
        () {
          final resolver = resolverFor(
            containersEnabled: containersEnabled,
            primary: ExecutionMode.host,
            agents: const [configuredRestricted],
          );

          expect(
            () => resolver.resolveForAgent(configuredRestricted, providerId: 'claude'),
            throwsA(
              isA<ExecutionPolicyException>().having(
                (error) => error.message,
                'message',
                allOf(contains('search'), contains('restricted'), contains('agent.execution: host')),
              ),
            ),
          );
        },
      );
    }

    test('the rejected agent is named at startup so it is not first seen at dispatch', () {
      final warnings = resolverFor(
        primary: ExecutionMode.host,
        agents: const [configuredRestricted],
      ).failClosedWarnings(agents: const [configuredRestricted]);

      expect(warnings.where((warning) => warning.contains('"search"')), hasLength(1));
    });

    test('a default profile is still dropped by the inherited mode, as before', () {
      // searchAgent carries the built-in restricted default, not an operator
      // choice, so `agent.execution: host` legitimately places it on the host.
      final resolver = resolverFor(primary: ExecutionMode.host, agents: const [searchAgent]);

      expect(resolver.resolveForAgent(searchAgent, providerId: 'claude'), const ExecutionPolicy.host());
      expect(resolver.hostOverrideWarnings().where((warning) => warning.contains('agent.execution')), hasLength(1));
    });

    test('an inherited container mode keeps the configured profile', () {
      expect(
        resolverFor(
          primary: ExecutionMode.container,
          agents: const [configuredRestricted],
        ).resolveForAgent(configuredRestricted, providerId: 'claude'),
        const ExecutionPolicy.container('restricted'),
      );
    });
  });

  group('S02 explicit agent and task-type choices coexist', () {
    const inheritingAgent = AgentDefinition(id: 'reviewer', description: 'reviews', prompt: 'review');
    const hostAgent = AgentDefinition(
      id: 'coder',
      description: 'writes code',
      prompt: 'code',
      execution: ExecutionMode.host,
    );

    final resolver = resolverFor(
      primary: ExecutionMode.container,
      agents: const [hostAgent, inheritingAgent],
      taskExecution: const {TaskType.coding: ExecutionMode.host},
    );

    test('an explicit logical-agent host override wins over the inherited mode', () {
      expect(resolver.resolveForAgent(hostAgent, providerId: 'claude'), const ExecutionPolicy.host());
    });

    test('an agent without an explicit setting inherits the primary agent mode', () {
      expect(
        resolver.resolveForAgent(inheritingAgent, providerId: 'claude'),
        const ExecutionPolicy.container('workspace'),
      );
      expect(resolver.resolveForPrimary(providerId: 'claude'), const ExecutionPolicy.container('workspace'));
    });

    test('a task-type override applies without touching unoverridden task types', () {
      expect(resolver.resolveForTaskType(TaskType.coding), const ExecutionPolicy.host());
      expect(resolver.resolveForTaskType(TaskType.research), const ExecutionPolicy.container('restricted'));
    });

    test('identityless contexts follow the deployment default, not agent.execution', () {
      final hostPrimary = resolverFor(primary: ExecutionMode.host);

      expect(hostPrimary.resolveForPrimary(providerId: 'claude'), const ExecutionPolicy.host());
      expect(
        hostPrimary.deploymentDefault,
        const ExecutionPolicy.container('workspace'),
        reason: 'the deployment default derives from container availability alone',
      );
    });
  });

  group('S05 unavailable boundaries fail closed', () {
    test('a resolved container profile with no manager is rejected, never substituted with host', () {
      final resolver = resolverFor(availableProfiles: const {'workspace'});

      expect(
        () => resolver.resolveForTaskType(TaskType.research),
        throwsA(
          isA<ExecutionPolicyException>().having(
            (error) => error.message,
            'message',
            allOf(contains('restricted'), contains('Available profiles: workspace')),
          ),
        ),
      );
    });

    test('an explicit container request without any container runtime is rejected', () {
      final resolver = resolverFor(containersEnabled: false, primary: ExecutionMode.container);

      expect(
        () => resolver.resolveForPrimary(providerId: 'claude'),
        throwsA(
          isA<ExecutionPolicyException>().having(
            (error) => error.message,
            'message',
            contains('container.enabled: true'),
          ),
        ),
      );
    });

    test('host policies never carry a container profile', () {
      final policies = [
        resolverFor(containersEnabled: false).resolveForPrimary(providerId: 'claude'),
        resolverFor(primary: ExecutionMode.host).resolveForPrimary(providerId: 'claude'),
      ];

      for (final policy in policies) {
        expect(policy.containerProfile, isNull);
        expect(policy.mode, ExecutionMode.host);
      }
    });
  });

  group('provider-declared container profiles resolve through the shared resolver', () {
    ExecutionPolicyResolver acpResolver(AcpContainerProfile profile, {ExecutionMode? primary}) =>
        ExecutionPolicyResolver(
          config: DartclawConfig.defaults().copyWith(
            container: const ContainerConfig(enabled: true),
            agent: AgentConfig(execution: primary),
            harness: HarnessConfig(
              acp: AcpConfig(
                agents: {
                  'goose': AcpAgentConfig(binary: 'goose', containerIsolationRequired: true, containerProfile: profile),
                },
              ),
            ),
          ),
          availableContainerProfiles: workspaceAndRestricted,
        );

    test('an ACP declared restricted profile is applied without a local mapping', () {
      expect(
        acpResolver(AcpContainerProfile.restricted).resolveForPrimary(providerId: 'goose'),
        const ExecutionPolicy.container('restricted'),
      );
    });

    test('an ACP declared workspace profile resolves to workspace', () {
      expect(
        acpResolver(AcpContainerProfile.workspace).resolveForPrimary(providerId: 'goose'),
        const ExecutionPolicy.container('workspace'),
      );
    });

    test('a logical agent overrides its provider declaration with its own profile', () {
      const restrictedAgent = AgentDefinition(
        id: 'search',
        description: 'searches',
        prompt: 'search',
        securityProfile: 'restricted',
      );

      expect(
        acpResolver(AcpContainerProfile.workspace).resolveForAgent(restrictedAgent, providerId: 'goose'),
        const ExecutionPolicy.container('restricted'),
      );
    });

    test('providers without a declaration fall back to the neutral profile', () {
      expect(
        acpResolver(AcpContainerProfile.restricted).resolveForPrimary(providerId: 'claude'),
        const ExecutionPolicy.container('workspace'),
      );
    });

    test('an inherited host mode is rejected rather than discarding the ACP declared profile', () {
      // `harness.acp.<id>.container_profile` is operator YAML exactly as an
      // agent's own `security_profile` is, so inheriting host must fail the
      // same way instead of silently dropping the boundary.
      const inheritingAgent = AgentDefinition(id: 'search', description: 'searches', prompt: 'search');

      expect(
        () => acpResolver(
          AcpContainerProfile.restricted,
          primary: ExecutionMode.host,
        ).resolveForAgent(inheritingAgent, providerId: 'goose'),
        throwsA(
          isA<ExecutionPolicyException>().having(
            (error) => error.message,
            'message',
            allOf(contains('search'), contains('restricted'), contains('agent.execution: host')),
          ),
        ),
      );
    });
  });

  group('pinned session routing', () {
    test('a pinned mode is used verbatim', () {
      final resolver = resolverFor();

      expect(
        resolver.resolveForPinnedSession(
          sessionId: 's1',
          executionMode: ExecutionMode.container,
          securityProfile: 'restricted',
        ),
        const ExecutionPolicy.container('restricted'),
      );
      expect(
        resolver.resolveForPinnedSession(
          sessionId: 's1',
          executionMode: ExecutionMode.host,
          securityProfile: 'restricted',
        ),
        const ExecutionPolicy.host(),
        reason: 'an explicit host pin drops the profile rather than contradicting it',
      );
    });

    test('a pre-upgrade session with an available pinned profile derives container mode', () {
      expect(
        resolverFor().resolveForPinnedSession(sessionId: 's1', securityProfile: 'restricted'),
        const ExecutionPolicy.container('restricted'),
      );
    });

    test('a pre-upgrade workspace pin without containers derives host — its real prior behavior', () {
      expect(
        resolverFor(containersEnabled: false).resolveForPinnedSession(sessionId: 's1', securityProfile: 'workspace'),
        const ExecutionPolicy.host(),
      );
      expect(
        resolverFor(containersEnabled: false).resolveForPinnedSession(sessionId: 's1'),
        const ExecutionPolicy.host(),
        reason: 'a missing mode alone is never a rejection',
      );
    });

    test('a pre-upgrade restricted pin without containers fails closed at resume', () {
      expect(
        () =>
            resolverFor(containersEnabled: false)
                .resolveForPinnedSession(sessionId: 's1', securityProfile: 'restricted'),
        throwsA(isA<ExecutionPolicyException>().having((error) => error.message, 'message', contains('s1'))),
      );
    });

    test('a rejection offers only remediations that can re-place a pinned session', () {
      // The resolver reads the session's own pinned routing, so no
      // `agent.execution` value can change the outcome for this session.
      final rejections = [
        () =>
            resolverFor(containersEnabled: false)
                .resolveForPinnedSession(sessionId: 's1', securityProfile: 'restricted'),
        () => resolverFor(containersEnabled: false).resolveForPinnedSession(
          sessionId: 's1',
          executionMode: ExecutionMode.container,
          securityProfile: 'restricted',
        ),
      ];

      for (final rejection in rejections) {
        expect(
          rejection,
          throwsA(
            isA<ExecutionPolicyException>().having(
              (error) => error.message,
              'message',
              allOf(contains('container.enabled: true'), isNot(contains('agent.execution'))),
            ),
          ),
        );
      }
    });
  });

  group('S06 startup warnings name each explicit weakening once', () {
    test('every explicitly overridden path is named exactly once', () {
      const hostAgent = AgentDefinition(
        id: 'coder',
        description: 'writes code',
        prompt: 'code',
        execution: ExecutionMode.host,
      );
      const inheritor = AgentDefinition(id: 'reviewer', description: 'reviews', prompt: 'review');
      final warnings = resolverFor(
        primary: ExecutionMode.host,
        agents: const [hostAgent, inheritor],
        taskExecution: const {TaskType.coding: ExecutionMode.host},
      ).hostOverrideWarnings();

      expect(warnings, hasLength(3));
      expect(warnings.where((warning) => warning.contains('agent.execution')), hasLength(1));
      expect(warnings.where((warning) => warning.contains('agent.agents.coder.execution')), hasLength(1));
      expect(warnings.where((warning) => warning.contains('tasks.execution.coding')), hasLength(1));
      expect(warnings.any((warning) => warning.contains('reviewer')), isFalse, reason: 'inheritors do not warn');
    });

    test('ordinary host defaults do not warn', () {
      expect(resolverFor(containersEnabled: false, agents: const [ordinaryAgent]).hostOverrideWarnings(), isEmpty);
      expect(resolverFor(agents: const [ordinaryAgent]).hostOverrideWarnings(), isEmpty);
    });

    test('a container-disabled deployment cannot weaken anything further', () {
      expect(resolverFor(containersEnabled: false, primary: ExecutionMode.host).hostOverrideWarnings(), isEmpty);
    });
  });

  group('S01 startup warns about contexts that will fail closed at first dispatch', () {
    test('a containers-disabled deployment names each unrunnable agent and task type', () {
      final warnings = resolverFor(
        containersEnabled: false,
        agents: const [ordinaryAgent, searchAgent],
      ).failClosedWarnings(agents: const [ordinaryAgent, searchAgent]);

      expect(warnings.where((warning) => warning.contains('"search"')), hasLength(1));
      expect(warnings.where((warning) => warning.contains('"research"')), hasLength(1));
      expect(warnings.any((warning) => warning.contains('"coder"')), isFalse, reason: 'a host-runnable agent is fine');
      expect(warnings.any((warning) => warning.contains('"coding"')), isFalse);
      expect(
        warnings.every((warning) => warning.contains(': host to run it on the host')),
        isTrue,
        reason: 'each warning carries the accepted remediation',
      );
    });

    test('built-in agents outside the configured definitions are still named', () {
      final warnings = resolverFor(containersEnabled: false).failClosedWarnings(agents: const [searchAgent]);

      expect(warnings.where((warning) => warning.contains('"search"')), hasLength(1));
    });

    test('a container-enabled deployment warns about nothing', () {
      expect(resolverFor(agents: const [searchAgent]).failClosedWarnings(agents: const [searchAgent]), isEmpty);
    });

    test('an explicit host selection resolves the fail-closed condition', () {
      const explicitHostSearch = AgentDefinition(
        id: 'search',
        description: 'searches',
        prompt: 'search',
        securityProfile: 'restricted',
        execution: ExecutionMode.host,
      );

      expect(
        resolverFor(
          containersEnabled: false,
          agents: const [explicitHostSearch],
          taskExecution: const {TaskType.research: ExecutionMode.host},
        ).failClosedWarnings(agents: const [explicitHostSearch]),
        isEmpty,
      );
    });
  });

  group('S05 startup names each unavailable provider/mode combination once', () {
    final acpInventory = ProviderExecutionInventory.of(
      providerIds: const ['claude', 'goose'],
      acpProviderIds: const {'goose'},
    );

    List<String> compatibilityWarnings(ExecutionPolicyResolver resolver, String providerId) =>
        resolver.providerCompatibilityWarnings(
          inventory: acpInventory,
          defaultProviderId: providerId,
          agents: const [ordinaryAgent, searchAgent],
        );

    /// Warnings about a resolved execution mode, excluding the policy-independent
    /// unsupported-surface line every ACP registration always earns.
    List<String> containerWarnings(List<String> warnings) =>
        warnings.where((warning) => !warning.contains('launch implementation')).toList();

    test('an ACP provider under a container policy names each mode once with path and remediation', () {
      final warnings = compatibilityWarnings(resolverFor(agents: const [ordinaryAgent, searchAgent]), 'goose');

      // The primary lane, both agents, and every task type reach the same two
      // resolved policies; the operator sees each combination once.
      final byMode = containerWarnings(warnings);
      expect(byMode.where((warning) => warning.contains('container/workspace')), hasLength(1));
      expect(byMode.where((warning) => warning.contains('container/restricted')), hasLength(1));
      expect(byMode, hasLength(2));
      expect(
        byMode.every(
          (warning) =>
              warning.contains('harness.acp.agents.goose') &&
              warning.contains('mediation for an ACP client') &&
              warning.contains('Select host execution'),
        ),
        isTrue,
      );
    });

    test('a registration with no launch implementation for a surface is named once', () {
      // Unavailability of a whole surface does not depend on the resolved
      // policy, so it is reported per provider rather than per context.
      for (final resolver in [
        resolverFor(agents: const [ordinaryAgent]),
        resolverFor(containersEnabled: false),
      ]) {
        expect(
          compatibilityWarnings(
            resolver,
            'goose',
          ).where((warning) => warning.contains('"goose" has no workflow one-shot launch implementation')),
          hasLength(1),
        );
      }
    });

    test('a provider whose container execution is mediated warns about nothing', () {
      final mediatedOnly = ProviderExecutionInventory.of(providerIds: const ['claude'], acpProviderIds: const {});

      expect(
        resolverFor(agents: const [ordinaryAgent, searchAgent]).providerCompatibilityWarnings(
          inventory: mediatedOnly,
          defaultProviderId: 'claude',
          agents: const [ordinaryAgent, searchAgent],
        ),
        isEmpty,
      );
    });

    test('host execution makes the ACP execution combinations available again', () {
      expect(containerWarnings(compatibilityWarnings(resolverFor(containersEnabled: false), 'goose')), isEmpty);
    });

    test('contexts that already fail policy resolution stay with the fail-closed warnings', () {
      // The restricted agent and research task type have no host equivalent
      // here, so they are unrunnable for every provider — a compatibility
      // warning would name the wrong cause.
      final resolver = resolverFor(containersEnabled: false, agents: const [ordinaryAgent, searchAgent]);

      expect(containerWarnings(compatibilityWarnings(resolver, 'goose')), isEmpty);
      expect(resolver.failClosedWarnings(agents: const [searchAgent]), isNotEmpty);
    });

    test('compatibility is checked after resolution and never substitutes a policy', () {
      final resolver = resolverFor(agents: const [ordinaryAgent]);

      expect(containerWarnings(compatibilityWarnings(resolver, 'goose')), isNotEmpty);
      expect(
        resolver.resolveForPrimary(providerId: 'goose'),
        const ExecutionPolicy.container('workspace'),
        reason: 'an unavailable combination is reported, not replaced',
      );
    });
  });
}
