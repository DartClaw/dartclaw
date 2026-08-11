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
    ExecutionPolicyResolver acpResolver(AcpContainerProfile profile) => ExecutionPolicyResolver(
      config: DartclawConfig.defaults().copyWith(
        container: const ContainerConfig(enabled: true),
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
        () => resolverFor(
          containersEnabled: false,
        ).resolveForPinnedSession(sessionId: 's1', securityProfile: 'restricted'),
        throwsA(isA<ExecutionPolicyException>().having((error) => error.message, 'message', contains('s1'))),
      );
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
}
