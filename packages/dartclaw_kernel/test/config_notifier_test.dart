import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

/// Test double for [Reconfigurable].
class _FakeReconfigurable implements Reconfigurable {
  final Set<String> _watchKeys;
  final bool shouldThrow;

  final List<ConfigDelta> received = [];

  new(this._watchKeys, {this.shouldThrow = false});

  @override
  Set<String> get watchKeys => _watchKeys;

  @override
  void reconfigure(ConfigDelta delta) {
    if (shouldThrow) throw StateError('reconfigure failed');
    received.add(delta);
  }
}

DartclawConfig _withAlerts({int cooldownSeconds = 300}) {
  return DartclawConfig(alerts: AlertsConfig(cooldownSeconds: cooldownSeconds));
}

DartclawConfig _withServer({int port = 3000, String host = 'localhost', String dataDir = '~/.dartclaw', String? name}) {
  return DartclawConfig(
    server: ServerConfig(port: port, host: host, dataDir: dataDir, name: name ?? 'DartClaw'),
  );
}

/// A config exercising every section the reload path compares, including the
/// four that were never diffed before (`harness`, `knowledge`, `workflow`,
/// `mcpServers`). Parsed rather than hand-built so section equality is proven
/// on values the loader actually produces.
const _populatedYaml = '''
port: 3100
name: Tiers
concurrency:
  max_parallel_turns: 4
agent:
  model: sonnet
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        container_isolation_required: true
        container_profile: restricted
knowledge:
  inbox:
    enabled: true
workflow:
  workspace_dir: /tmp/workflows
credentials:
  docs:
    api_key: \${DOCS_API_KEY}
mcp_servers:
  docs:
    command: docs-server
    network_class: local
    credential: docs
providers:
  claude:
    executable: claude
    pool_size: 2
sessions:
  reset_hour: 5
context:
  reserve_tokens: 25000
alerts:
  enabled: true
  cooldown_seconds: 90
logging:
  redact_patterns:
    - secret
scheduling:
  heartbeat:
    interval_minutes: 30
governance:
  queue_strategy: fair
''';

const _populatedEnv = {'HOME': defaultTestHome, 'DOCS_API_KEY': 'docs-secret'};

void main() {
  group('ConfigNotifier', () {
    late DartclawConfig base;
    late ConfigNotifier notifier;

    setUp(() {
      base = const DartclawConfig.defaults();
      notifier = ConfigNotifier(base);
    });

    test('holds initial config', () {
      expect(notifier.current, same(base));
    });

    // -----------------------------------------------------------------------
    // The declared section→tier table
    // -----------------------------------------------------------------------

    group('declared reload tiers', () {
      test('exactly these sections are live-diffed; every other section is restart tier', () {
        final reloadable = {
          for (final entry in ConfigNotifier.sectionTiers.entries)
            if (entry.value == ConfigReloadTier.reloadable) entry.key,
        };

        // One entry per section with a registered service that genuinely
        // applies the change: SessionLockManager, SessionResetService,
        // ContextMonitor/ResultTrimmer, SecurityWiring, the redactor adapter,
        // WorkspaceGitSync and AlertRouter.
        expect(reloadable, {'server', 'sessions', 'context', 'security', 'logging', 'workspace', 'alerts'});
        expect(
          {
            for (final entry in ConfigNotifier.sectionTiers.entries)
              if (entry.value == ConfigReloadTier.restart) entry.key,
          },
          {
            'agent',
            'auth',
            'gateway',
            'harness',
            'memory',
            'knowledge',
            'search',
            'mcpServers',
            'providers',
            'credentials',
            'tasks',
            'scheduling',
            'onboarding',
            'workflow',
            'usage',
            'container',
            'channels',
            'governance',
            'features',
            'projects',
          },
        );
      });

      test('names every section exactly once and excludes only extensions', () {
        // `extensions` has no value equality, so `!=` between two parses of the
        // same file is always true — see the fitness allowlist for the record.
        expect(ConfigNotifier.sectionTiers, isNot(contains('extensions')));
        expect(ConfigNotifier.sectionTiers, hasLength(27));
      });

      test('the tier table is not mutable through its public view', () {
        expect(() => ConfigNotifier.sectionTiers['harness'] = ConfigReloadTier.reloadable, throwsUnsupportedError);
      });
    });

    // -----------------------------------------------------------------------
    // Restart-tier changes are detected, reported, and withheld
    // -----------------------------------------------------------------------

    test('a harness change is reported restart-required, produces no delta and notifies nobody', () {
      final service = _FakeReconfigurable({'context.*'});
      notifier.register(service);

      final delta = notifier.reload(
        const DartclawConfig(
          harness: HarnessConfig(
            sections: {
              'test': {'enabled': true},
            },
          ),
        ),
      );

      expect(delta, isNull);
      expect(notifier.restartRequiredSections, {'harness'});
      expect(service.received, isEmpty);
    });

    test('a mixed edit applies the reloadable section and withholds the restart-tier one', () {
      final service = _FakeReconfigurable({'context.*'});
      notifier.register(service);

      final delta = notifier.reload(
        const DartclawConfig(
          context: ContextConfig(reserveTokens: 30000),
          providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude-next')}),
        ),
      );

      expect(delta, isNotNull);
      expect(delta!.changedKeys, contains('context.*'));
      expect(delta.changedKeys, isNot(contains('providers.*')));
      expect(notifier.restartRequiredSections, {'providers'});
      expect(service.received, hasLength(1));
    });

    test('reloading an unedited parsed config reports neither a delta nor a restart requirement', () {
      // The four newly compared sections have never been through `==`; two
      // parses of one file must still compare equal at every nesting level.
      final first = loadYaml(_populatedYaml, env: _populatedEnv);
      const defaults = DartclawConfig.defaults();
      // Without this the comparison below could pass on four default instances.
      expect(first.harness, isNot(defaults.harness));
      expect(first.harness.sections['acp'], isNotNull);
      expect(first.knowledge, isNot(defaults.knowledge));
      expect(first.workflow, isNot(defaults.workflow));
      expect(first.mcpServers, isNot(defaults.mcpServers));

      final notifier = ConfigNotifier(first);
      final delta = notifier.reload(loadYaml(_populatedYaml, env: _populatedEnv));

      expect(delta, isNull);
      expect(notifier.restartRequiredSections, isEmpty);
    });

    test('a later clean reload clears a previously reported restart requirement', () {
      final populated = loadYaml(_populatedYaml, env: _populatedEnv);
      final notifier = ConfigNotifier(populated);

      notifier.reload(loadYaml(_populatedYaml.replaceFirst('binary: goose', 'binary: goose-next'), env: _populatedEnv));
      expect(notifier.restartRequiredSections, {'harness'});

      notifier.reload(loadYaml(_populatedYaml, env: _populatedEnv));
      expect(notifier.restartRequiredSections, isEmpty);
    });

    test('a reloadable alerts change reaches its watchers', () {
      final service = _FakeReconfigurable({'alerts.*'});
      notifier.register(service);

      final delta = notifier.reload(const DartclawConfig(alerts: AlertsConfig(enabled: true)));

      expect(delta, isNotNull);
      expect(delta!.changedKeys, contains('alerts.*'));
      expect(service.received, hasLength(1));
      expect(service.received.first.current.alerts.enabled, isTrue);
    });

    test('reload with no changes returns null', () {
      final delta = notifier.reload(const DartclawConfig.defaults());
      expect(delta, isNull);
    });

    // -----------------------------------------------------------------------
    // Registration admission
    // -----------------------------------------------------------------------

    group('registration admission', () {
      test('a service watching a restart-tier section is refused, naming the section and its tier', () {
        // The other half of "a watcher that can never fire cannot register" —
        // a section missing from the table entirely is caught by the
        // config_section_tier_coverage fitness gate, which is what the dead
        // AlertRouter (a watcher on a section reload() never compared) needed.
        expect(
          () => notifier.register(_FakeReconfigurable({'workflow.*'})),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.toString(),
              'message',
              allOf(contains('workflow'), contains('restart')),
            ),
          ),
        );
      });

      test('a specific watch key resolves to its section, not just the glob form', () {
        expect(() => notifier.register(_FakeReconfigurable({'governance.rate_limits'})), throwsArgumentError);
      });

      test('a service watching a live-diffed section registers and still receives its deltas', () {
        final service = _FakeReconfigurable({'context.*'});
        notifier.register(service);

        notifier.reload(const DartclawConfig(context: ContextConfig(reserveTokens: 30000)));

        expect(service.received, hasLength(1));
      });
    });

    test('reload does NOT notify service with non-matching watchKeys', () {
      final alertsService = _FakeReconfigurable({'alerts.*'});
      final guardsService = _FakeReconfigurable({'security.*'});
      notifier
        ..register(alertsService)
        ..register(guardsService);

      notifier.reload(_withAlerts(cooldownSeconds: 45));

      expect(alertsService.received, hasLength(1));
      expect(guardsService.received, isEmpty);
    });

    test('unregistered service is not notified', () {
      final service = _FakeReconfigurable({'alerts.*'});
      notifier.register(service);
      notifier.unregister(service);

      notifier.reload(_withAlerts(cooldownSeconds: 45));

      expect(service.received, isEmpty);
    });

    test('register same service twice causes only one notification', () {
      final service = _FakeReconfigurable({'alerts.*'});
      notifier.register(service);
      notifier.register(service); // duplicate

      notifier.reload(_withAlerts(cooldownSeconds: 45));

      expect(service.received, hasLength(1));
    });

    test('reload with only non-reloadable server changes returns null delta', () {
      final initial = _withServer(port: 3000, host: 'localhost');
      notifier = ConfigNotifier(initial);

      final service = _FakeReconfigurable({'server.*'});
      notifier.register(service);

      // Change only port (non-reloadable)
      final updated = _withServer(port: 9999, host: 'localhost');
      final delta = notifier.reload(updated);

      expect(delta, isNull);
      expect(service.received, isEmpty);
    });

    test('reload with server non-reloadable and reloadable changes includes server.* in delta', () {
      final initial = _withServer(port: 3000, host: 'localhost', name: 'Old');
      notifier = ConfigNotifier(initial);

      final service = _FakeReconfigurable({'server.*'});
      notifier.register(service);

      // Change port (non-reloadable) AND name (reloadable)
      final updated = _withServer(port: 9999, host: '0.0.0.0', dataDir: '/new/data', name: 'New');
      final delta = notifier.reload(updated);

      expect(delta, isNotNull);
      expect(delta!.changedKeys, contains('server.*'));
      expect(service.received, hasLength(1));
      expect(delta.current.server.port, 3000);
      expect(delta.current.server.host, 'localhost');
      expect(delta.current.server.dataDir, '~/.dartclaw');
      expect(delta.current.server.name, 'New');
      expect(notifier.current.server, delta.current.server);
    });

    test('best-effort: throwing service does not prevent other services from being notified', () {
      final throwingService = _FakeReconfigurable({'alerts.*'}, shouldThrow: true);
      final goodService1 = _FakeReconfigurable({'alerts.*'});
      final goodService2 = _FakeReconfigurable({'alerts.*'});

      notifier
        ..register(goodService1)
        ..register(throwingService)
        ..register(goodService2);

      final delta = notifier.reload(_withAlerts(cooldownSeconds: 45));

      expect(delta, isNotNull);
      expect(goodService1.received, hasLength(1));
      expect(goodService2.received, hasLength(1));
    });

    test('reload updates current config', () {
      final updated = _withAlerts(cooldownSeconds: 45);
      notifier.reload(updated);

      expect(notifier.current, same(updated));
    });

    // A reload re-parses the file, and an absent `container:` section parses as
    // disabled — so without carrying it forward, any reload of any field would
    // silently un-resolve a posture the startup probe settled. `container.*` is
    // restart-tier, so the value in force is the right one to keep.
    test('reload carries the resolved container posture forward', () {
      const resolved = DartclawConfig(container: ContainerConfig(enabled: true));
      notifier = ConfigNotifier(resolved);

      notifier.reload(_withAlerts(cooldownSeconds: 45));

      expect(notifier.current.container.enabled, isTrue);
    });

    test('reload rejects blocking parser diagnostics without replacing current config', () {
      notifier.reload(const DartclawConfig(governance: GovernanceConfig(queueStrategy: QueueStrategy.fair)));
      final invalid = DartclawConfig(warnings: ['invalid reload value']);

      expect(() => notifier.reload(invalid), throwsFormatException);
      expect(notifier.current, same(base));
      // The guard rejects before anything is recorded, so the standing report survives.
      expect(notifier.restartRequiredSections, {'governance'});
    });

    test('reload rejects container isolation on native Windows at the notifier boundary', () {
      notifier = ConfigNotifier(base, platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'));
      notifier.reload(const DartclawConfig(governance: GovernanceConfig(queueStrategy: QueueStrategy.fair)));
      const unsupported = DartclawConfig(container: ContainerConfig(enabled: true));

      expect(() => notifier.reload(unsupported), throwsA(isA<UnsupportedCapabilityError>()));
      expect(notifier.current, same(base));
      expect(notifier.restartRequiredSections, {'governance'});
    });

    test('delta contains correct previous and current config', () {
      final updated = _withAlerts(cooldownSeconds: 45);
      final delta = notifier.reload(updated)!;

      expect(delta.previous, same(base));
      expect(delta.current, same(updated));
    });

    test('reload with multiple changed sections includes all in delta', () {
      final service = _FakeReconfigurable({'alerts.*', 'workspace.*'});
      notifier.register(service);

      const updated = DartclawConfig(
        alerts: AlertsConfig(cooldownSeconds: 45),
        workspace: WorkspaceConfig(gitSyncEnabled: false),
      );
      final delta = notifier.reload(updated);

      expect(delta, isNotNull);
      expect(delta!.changedKeys, containsAll(['alerts.*', 'workspace.*']));
      expect(service.received, hasLength(1));
    });
  });
}
