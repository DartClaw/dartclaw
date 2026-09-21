import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/model_catalogue_discovery.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during model catalogue test');

const _catalogue = ModelCatalogue(
  entries: [
    ModelCatalogueEntry(id: 'sonnet', label: 'Sonnet', efforts: ['low', 'high']),
  ],
  defaultId: 'sonnet',
);

final class _CatalogueHarness extends FakeAgentHarness implements ModelCatalogueProvider {
  new() : super(promptStrategy: PromptStrategy.append);

  int discoveries = 0;

  @override
  Future<ModelCatalogue> discoverModelCatalogue() async {
    discoveries++;
    return _catalogue;
  }
}

void main() {
  group('model catalogue discovery', () {
    group('retry policy', () {
      late DateTime now;
      late List<Completer<ModelCatalogue>> attempts;
      late ModelCatalogueDiscovery discovery;

      setUp(() {
        now = DateTime.utc(2026, 9, 21, 12);
        attempts = [];
        discovery = ModelCatalogueDiscovery(
          providers: const ['claude'],
          discover: (_) => (attempts..add(Completer<ModelCatalogue>())).last.future,
          now: () => now,
        );
      });

      test('a failed provider is retried once by the first read 5 minutes later, never sooner', () async {
        final logs = <LogRecord>[];
        final subscription = Logger('ModelCatalogueDiscovery').onRecord.listen(logs.add);
        addTearDown(subscription.cancel);

        discovery.start();
        expect(attempts, hasLength(1));
        attempts.single.completeError(StateError('initialize timed out'));
        await pumpEventQueue();
        // Each failure is logged under the provider it belongs to.
        expect(logs.map((record) => record.message), contains(contains('"claude"')));

        now = now.add(ModelCatalogueDiscovery.retryAfter - const Duration(seconds: 1));
        expect(discovery.catalogueFor('claude'), isNull);
        discovery.start();
        await pumpEventQueue();
        expect(attempts, hasLength(1), reason: 'reads within 5 minutes of a failure must start nothing');

        now = now.add(const Duration(seconds: 1));
        expect(discovery.catalogueFor('claude'), isNull);
        expect(discovery.catalogueFor('claude'), isNull);
        expect(attempts, hasLength(2), reason: 'concurrent reads start exactly one retry');

        attempts.last.complete(_catalogue);
        await pumpEventQueue();
        expect(discovery.catalogueFor('claude'), same(_catalogue));

        now = now.add(const Duration(days: 1));
        discovery.start();
        expect(discovery.catalogueFor('claude'), same(_catalogue));
        expect(attempts, hasLength(2), reason: 'a catalogue that arrived is kept for the process');
      });

      test('a provider outside the discovered set is never probed', () {
        expect(discovery.catalogueFor('acp'), isNull);
        expect(attempts, isEmpty);
      });
    });

    group('startup', () {
      late Directory tempDir;
      StorageWiring? storage;
      SecurityWiring? security;
      HarnessWiring? harnessWiring;

      setUp(() => tempDir = Directory.systemTemp.createTempSync('dartclaw_model_catalogue_'));

      tearDown(() async {
        await harnessWiring?.executions.dispose();
        await security?.dispose();
        await storage?.dispose();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('discovers on the host from the worker\'s inputs and stops the probe', () async {
        final config = DartclawConfig(
          server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
          agent: const AgentConfig(provider: 'claude', model: 'sonnet', effort: 'high'),
          providers: ProvidersConfig(
            entries: {
              'claude': ProviderEntry(
                executable: Platform.resolvedExecutable,
                poolSize: 1,
                options: const {'approval': 'never'},
              ),
            },
          ),
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
          gateway: const GatewayConfig(authMode: 'none'),
        );
        await writeWorkspacePromptFiles(config.workspaceDir);
        final eventBus = EventBus();
        final created = <(HarnessFactoryConfig, _CatalogueHarness)>[];
        final factory = HarnessFactory()
          ..register('claude', (factoryConfig) {
            final harness = _CatalogueHarness();
            created.add((factoryConfig, harness));
            return harness;
          });
        storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
        security = await wireTestSecurity(
          config: config,
          dataDir: tempDir.path,
          eventBus: eventBus,
          exitFn: _unexpectedExit,
        );
        harnessWiring = await wireTestHarness(
          config: config,
          dataDir: tempDir.path,
          harnessFactory: factory,
          exitFn: _unexpectedExit,
          storage: storage!,
          security: security!,
          eventBus: eventBus,
          serverRefGetter: () => throw UnimplementedError(),
        );
        harnessWiring!.startModelCatalogueDiscovery();

        for (var i = 0; i < 100 && harnessWiring!.modelCatalogueFor('claude') == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(harnessWiring!.modelCatalogueFor('claude'), same(_catalogue));

        final primary = created.first;
        final probe = created.singleWhere((entry) => entry.$2.discoveries > 0);
        expect(created.where((entry) => entry.$2.discoveries > 0), hasLength(1));
        final probeConfig = probe.$1;
        expect(probeConfig.containerManager, isNull);
        expect(probeConfig.executable, primary.$1.executable);
        expect(probeConfig.providerOptions, primary.$1.providerOptions);
        expect(probeConfig.environment, primary.$1.environment);
        expect(probeConfig.environment['ANTHROPIC_API_KEY'], 'anthropic-key');
        expect(probeConfig.harnessConfig.model, 'sonnet');
        expect(probeConfig.harnessConfig.effort, 'high');
        // No guard chain, MCP endpoint, persona or workspace root rides along.
        expect(probeConfig.guardChain, isNull);
        expect(probeConfig.harnessConfig.mcpServerUrl, isNull);
        expect(probeConfig.harnessConfig.appendSystemPrompt, isNull);
        expect(probeConfig.skillWorkspaceDir, isNull);
        expect(probeConfig.declaredWritableRoots, isEmpty);
        expect(probe.$2.disposeCalled, isTrue);
        expect(primary.$2.disposeCalled, isFalse);
      });
    });
  });
}
