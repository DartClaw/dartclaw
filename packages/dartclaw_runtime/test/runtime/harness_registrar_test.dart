import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExecutionAdmission, ExecutionRequest, ExecutionSurface;
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during harness registrar test');
}

/// Contributes one provider the server package never names.
///
/// Lives in the test tree on purpose: nothing under
/// `packages/dartclaw_runtime/lib` may name this type or the family it stands
/// in for.
final class _StubRegistrar implements HarnessRegistrar {
  new({
    required this.providerEntry,
    this.declareThrows = false,
    this.activateThrows = false,
    this.declaresOverlay = true,
    this.profile = 'restricted',
    this.overlaySecret = 'acme-secret',
  });

  final ProviderEntry providerEntry;
  final bool declareThrows;
  final bool activateThrows;
  final bool declaresOverlay;
  final String? profile;
  final String overlaySecret;

  final createdConfigs = <HarnessFactoryConfig>[];
  var declareCalls = 0;
  var activateCalls = 0;
  var primeCalls = 0;

  @override
  void primeConfigSections(DartclawConfig config) => primeCalls += 1;

  static const providerId = 'acme';
  static const overlayVar = 'ACME_TOKEN';
  static const warning = 'acme: pool size settled by probe';

  HarnessRegistration get _registration => HarnessRegistration(
    providerEntries: {providerId: providerEntry},
    containerProfileFor: (id) => id == providerId ? profile : null,
    credentialOverlayFor: declaresOverlay
        ? (id, environment) => id == providerId ? {...environment, overlayVar: overlaySecret} : environment
        : null,
    warnings: const [warning],
  );

  @override
  HarnessRegistration declare(DartclawConfig config) {
    declareCalls++;
    if (declareThrows) throw StateError('acme registration is not configurable on this host');
    return _registration;
  }

  @override
  Future<HarnessRegistration> activate(DartclawConfig config, HarnessFactory factory) async {
    activateCalls++;
    if (activateThrows) throw StateError('acme probe failed');
    factory.registerFirstClaim(providerId, (config) {
      createdConfigs.add(config);
      return FakeAgentHarness(promptStrategy: PromptStrategy.append);
    });
    return _registration;
  }
}

void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_registrar_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key', envVars: ['ANTHROPIC_API_KEY']),
        },
      ),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    await writeWorkspacePromptFiles(config.workspaceDir);
    eventBus = EventBus();
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<HarnessWiring> wire({List<HarnessRegistrar> registrars = const [], HarnessFactory? factory}) async {
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
    final harnessFactory = factory ?? HarnessFactory();
    harnessFactory.register('claude', (_) => FakeAgentHarness(promptStrategy: PromptStrategy.append));
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: harnessFactory,
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      harnessRegistrars: registrars,
      environment: const {'PATH': '/usr/bin'},
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
    );
    return harnessWiring!;
  }

  group('no registrar supplied', () {
    test('the empty default owns no provider and leaves the effective entries at config.providers', () async {
      final wiring = await wire();

      expect(wiring.executionInventory.supports.keys, ['claude']);
      expect(
        wiring.executionInventory.supports['claude']!.registrationYamlPath,
        'providers.claude',
        reason: 'a build with no registrar records the built-in family, never an owned registration',
      );
      expect(wiring.providerStatusEntries.keys, ['claude']);
    });
  });

  group('a registrar contributes a provider the server package never names', () {
    test('its provider is owned, and its factory, overlay and warning all reach the runtime', () async {
      final warnings = <String>[];
      final subscription = Logger.root.onRecord.listen((record) {
        if (record.level >= Level.WARNING) warnings.add(record.message);
      });
      addTearDown(subscription.cancel);

      final registrar = _StubRegistrar(
        // `credentials_required: false` is the registration declaring that it
        // presents its own credential — the same thing an ACP entry declares,
        // and what keeps the first-party validator from demanding one.
        providerEntry: ProviderEntry(
          executable: Platform.resolvedExecutable,
          poolSize: 1,
          options: const {'credentials_required': false},
        ),
      );
      final wiring = await wire(registrars: [registrar]);

      expect(registrar.declareCalls, 1);
      expect(registrar.activateCalls, 1);
      expect(
        wiring.executionInventory.supports[_StubRegistrar.providerId]!.registrationYamlPath,
        contains(_StubRegistrar.providerId),
        reason: 'the registrar-owned ID reaches the inventory as an owned registration',
      );
      expect(wiring.providerStatusEntries.keys, contains(_StubRegistrar.providerId));
      expect(warnings, contains(_StubRegistrar.warning));

      final lease = await wiring.executions.acquire(
        const ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: _StubRegistrar.providerId,
          policy: ExecutionPolicy.host(),
          sessionId: 'acme-1',
          admission: ExecutionAdmission.wait,
        ),
      );
      addTearDown(() async => lease?.release());

      expect(registrar.createdConfigs, hasLength(1), reason: 'worker creation resolves the registered factory');
      expect(registrar.createdConfigs.single.environment[_StubRegistrar.overlayVar], 'acme-secret');
      expect(
        registrar.createdConfigs.single.environment.containsKey('ANTHROPIC_API_KEY'),
        isFalse,
        reason: 'a registration owning the provider replaces the first-party credential arm entirely',
      );
    });

    test('a registration owning a provider but declaring no overlay presents no first-party credential', () async {
      final registrar = _StubRegistrar(
        providerEntry: ProviderEntry(
          executable: Platform.resolvedExecutable,
          poolSize: 1,
          options: const {'credentials_required': false},
        ),
        declaresOverlay: false,
      );
      final wiring = await wire(registrars: [registrar]);

      final lease = await wiring.executions.acquire(
        const ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: _StubRegistrar.providerId,
          policy: ExecutionPolicy.host(),
          sessionId: 'acme-no-overlay',
          admission: ExecutionAdmission.wait,
          spawnEnvironment: {_StubRegistrar.overlayVar: 'step-owned-secret'},
        ),
      );
      addTearDown(() async => lease?.release());

      expect(
        registrar.createdConfigs.single.environment.containsKey('ANTHROPIC_API_KEY'),
        isFalse,
        reason: 'ownership decides, not the overlay callback nullability - the ACP arm behaves the same way',
      );
      expect(registrar.createdConfigs.single.environment.containsKey(_StubRegistrar.overlayVar), isFalse);
    });

    test('two claims resolve entry profile overlay and factory through the first registrar', () async {
      final warnings = <String>[];
      final subscription = Logger.root.onRecord.listen((record) => warnings.add(record.message));
      addTearDown(subscription.cancel);
      config = config.copyWith(
        agent: const AgentConfig(
          provider: 'claude',
          definitions: [AgentDefinition(id: 'acme-user', description: 'uses acme', prompt: 'work', provider: 'acme')],
        ),
      );
      final first = _StubRegistrar(
        providerEntry: ProviderEntry(
          executable: Platform.resolvedExecutable,
          poolSize: 1,
          options: const {'credentials_required': false},
        ),
        overlaySecret: 'first-secret',
      );
      final second = _StubRegistrar(
        providerEntry: const ProviderEntry(
          executable: '/second-claim',
          poolSize: 2,
          options: {'credentials_required': false},
        ),
        profile: 'workspace',
        overlaySecret: 'second-secret',
      );

      final wiring = await wire(registrars: [first, second]);
      final lease = await wiring.executions.acquire(
        const ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: _StubRegistrar.providerId,
          policy: ExecutionPolicy.host(),
          sessionId: 'first-claim',
          admission: ExecutionAdmission.wait,
        ),
      );
      addTearDown(() async => lease?.release());

      expect(wiring.providerStatusEntries[_StubRegistrar.providerId]!.executable, Platform.resolvedExecutable);
      expect(first.createdConfigs.single.environment[_StubRegistrar.overlayVar], 'first-secret');
      expect(second.createdConfigs, isEmpty);
      expect(warnings, contains(contains('acme-user')));
      expect(warnings, contains(contains('restricted')));
    });

    test('a declare throw aborts assembly with the registrar own message', () async {
      final registrar = _StubRegistrar(
        providerEntry: ProviderEntry(executable: Platform.resolvedExecutable),
        declareThrows: true,
      );

      await expectLater(
        wire(registrars: [registrar]),
        throwsA(
          isA<StateError>().having((error) => error.message, 'message', contains('not configurable on this host')),
        ),
      );
      expect(registrar.activateCalls, 0, reason: 'assembly stops before activation');
    });

    test('an activate throw aborts assembly before any worker is spawned', () async {
      final registrar = _StubRegistrar(
        providerEntry: ProviderEntry(executable: Platform.resolvedExecutable),
        activateThrows: true,
      );

      await expectLater(
        wire(registrars: [registrar]),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('acme probe failed'))),
      );
      expect(registrar.createdConfigs, isEmpty);
    });
  });

  test('no file under lib names the stub type or the provider family it stands in for', () async {
    // Resolved through the package URI rather than the cwd: sibling suites move
    // `Directory.current` process-wide, and a cwd-probed root would silently
    // scan a different tree.
    final libUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
    final libDir = Directory(p.dirname(libUri!.toFilePath()));
    final sources = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    expect(sources, isNotEmpty, reason: 'an empty scan would pass vacuously');

    final offenders = sources
        .where((file) {
          final source = file.readAsStringSync();
          return source.contains('_StubRegistrar') || source.contains(_StubRegistrar.providerId);
        })
        .map((file) => file.path)
        .toList();

    expect(offenders, isEmpty);
  });
}
