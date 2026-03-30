import 'package:dartclaw_security/dartclaw_security.dart';

import '../config/history_config.dart';
import 'agent_harness.dart';
import 'claude_code_harness.dart';
import 'codex_exec_harness.dart';
import 'codex_harness.dart';
import '../container/container_manager.dart';
import 'harness_config.dart';

/// Configuration bundle used when constructing a harness through [HarnessFactory].
class HarnessFactoryConfig {
  /// Current working directory for the harness process.
  final String cwd;

  /// Executable path for the provider binary.
  final String executable;

  /// Timeout applied to a single turn.
  final Duration turnTimeout;

  /// Provider-agnostic harness configuration forwarded during initialization.
  final HarnessConfig harnessConfig;

  /// Provider-specific options forwarded to the concrete harness.
  final Map<String, dynamic> providerOptions;

  /// Environment variables visible to the provider subprocess.
  final Map<String, String> environment;

  /// Optional container manager used to spawn the harness in isolation.
  final ContainerManager? containerManager;

  /// Optional guard evaluation chain used by Claude harnesses.
  final GuardChain? guardChain;

  /// Optional guard audit logger used by Claude harnesses.
  final GuardAuditLogger? auditLogger;

  /// Memory save callback used when the internal MCP server is not configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySave;

  /// Memory search callback used when the internal MCP server is not configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch;

  /// Memory read callback used when the internal MCP server is not configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead;

  /// History replay configuration for Claude harnesses.
  final HistoryConfig historyConfig;

  /// Creates an immutable harness-construction configuration.
  const HarnessFactoryConfig({
    required this.cwd,
    this.executable = 'claude',
    this.turnTimeout = const Duration(seconds: 600),
    this.harnessConfig = const HarnessConfig(),
    this.historyConfig = const HistoryConfig.defaults(),
    this.providerOptions = const <String, dynamic>{},
    this.environment = const <String, String>{},
    this.containerManager,
    this.guardChain,
    this.auditLogger,
    this.onMemorySave,
    this.onMemorySearch,
    this.onMemoryRead,
  });
}

/// Factory for creating [AgentHarness] instances by provider identifier.
class HarnessFactory {
  final Map<String, AgentHarness Function(HarnessFactoryConfig config)> _factories = {};

  /// Creates a factory with built-in provider registrations.
  HarnessFactory() {
    register('claude', _createClaudeHarness);
    register('codex', _createCodexHarness);
    register('codex-exec', _createCodexExecHarness);
  }

  /// Registers a provider-specific harness factory.
  void register(String providerId, AgentHarness Function(HarnessFactoryConfig config) factory) {
    _factories[providerId] = factory;
  }

  /// Creates a harness for [providerId] using [config].
  ///
  /// Throws [ArgumentError] when the provider is not registered.
  AgentHarness create(String providerId, HarnessFactoryConfig config) {
    final factory = _factories[providerId];
    if (factory == null) {
      throw ArgumentError('No harness factory registered for provider: $providerId');
    }
    return factory(config);
  }

  /// Returns whether a factory is registered for [providerId].
  bool supports(String providerId) => _factories.containsKey(providerId);

  /// Returns the registered provider identifiers.
  Iterable<String> get registeredProviders => _factories.keys;
}

AgentHarness _createClaudeHarness(HarnessFactoryConfig config) {
  return ClaudeCodeHarness(
    claudeExecutable: config.executable,
    cwd: config.cwd,
    turnTimeout: config.turnTimeout,
    onMemorySave: config.onMemorySave,
    onMemorySearch: config.onMemorySearch,
    onMemoryRead: config.onMemoryRead,
    harnessConfig: config.harnessConfig,
    historyConfig: config.historyConfig,
    containerManager: config.containerManager,
    environment: config.environment,
    guardChain: config.guardChain,
    auditLogger: config.auditLogger,
  );
}

AgentHarness _createCodexHarness(HarnessFactoryConfig config) {
  return CodexHarness(
    cwd: config.cwd,
    executable: config.executable == 'claude' ? 'codex' : config.executable,
    turnTimeout: config.turnTimeout,
    environment: config.environment,
    harnessConfig: config.harnessConfig,
    providerOptions: config.providerOptions,
    guardChain: config.guardChain,
  );
}

AgentHarness _createCodexExecHarness(HarnessFactoryConfig config) {
  final sandboxMode = config.providerOptions['sandbox'];
  return CodexExecHarness(
    cwd: config.cwd,
    codexExecutable: config.executable == 'claude' ? 'codex' : config.executable,
    sandboxMode: sandboxMode is String && sandboxMode.trim().isNotEmpty ? sandboxMode : 'danger-full-access',
    turnTimeout: config.turnTimeout,
    harnessConfig: config.harnessConfig,
    environment: config.environment,
  );
}
