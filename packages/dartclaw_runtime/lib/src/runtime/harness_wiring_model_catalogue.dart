part of 'harness_wiring.dart';

extension _HarnessWiringModelCatalogue on HarnessWiring {
  /// Discovery over every executable provider whose harness reports a catalogue.
  ModelCatalogueDiscovery _buildModelCatalogueDiscovery() {
    final providers = {defaultProviderId, ..._executions.snapshot.providers.keys}.where(
      (providerId) =>
          _harnessFactory.supports(providerId) &&
          _harnessFactory.create(providerId, const HarnessFactoryConfig(cwd: '/')) is ModelCatalogueProvider,
    );
    return ModelCatalogueDiscovery(providers: providers, discover: _discoverModelCatalogue);
  }

  /// Reads [providerId]'s catalogue from a probe built on the host from the
  /// inputs its workers spawn with – executable, provider options, configured
  /// model and effort, credential environment, subscription home – so the list
  /// and the resolved default describe the account and model its turns run.
  /// No container, guard chain, workspace root or MCP wiring rides along.
  Future<ModelCatalogue> _discoverModelCatalogue(String providerId) async {
    final verdict = _executionInventory.verdictFor(providerId: providerId, policy: const ExecutionPolicy.host());
    if (!verdict.isSupported) throw StateError(verdict.message);
    final target = resolveProviderTarget(config, providerId, registeredProviders: _registrarProviderEntries);
    final probe = _harnessFactory.create(
      providerId,
      HarnessFactoryConfig(
        cwd: Directory.current.path,
        executable: target.executable,
        providerOptions: target.options,
        harnessConfig: HarnessLaunchOptions(model: config.agent.model, effort: config.agent.effort),
        environment: buildProviderSpawnEnvironment(
          target: target,
          registry: _credentialRegistry(),
          baseEnvironment: _environment,
          registrarOverlay: _registrarCredentialOverlay,
        ),
        prepareSubscriptionHome: _subscriptionHomeFor(providerId),
        platformCapabilities: _platformCapabilities,
      ),
    );
    try {
      if (probe is! ModelCatalogueProvider) throw StateError('Provider "$providerId" reports no model catalogue');
      return await (probe as ModelCatalogueProvider).discoverModelCatalogue();
    } finally {
      await probe.dispose();
    }
  }
}
