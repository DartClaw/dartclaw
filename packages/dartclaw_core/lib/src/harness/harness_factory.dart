import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import 'agent_harness.dart';
import 'claude_code_harness.dart';
import 'claude_protocol_adapter.dart';
import 'canonical_tool.dart';
import 'codex_harness.dart';
import 'codex_protocol_adapter.dart';
import '../container/container_executor.dart';
import 'harness_launch_options.dart';
import 'process_types.dart';

/// Configuration bundle used when constructing a harness through [HarnessFactory].
class HarnessFactoryConfig {
  /// Current working directory for the harness process.
  ///
  /// When constructing a harness purely to probe capability flags
  /// (`supportsSessionContinuity`, `skillActivationLine`, etc.) without
  /// ever calling `start()`, the factory convention is to pass
  /// `cwd: '/'` to signal "no real working directory required". See
  /// [HarnessFactory.probeContinuityProviders] and
  /// [HarnessFactory.skillActivationLineFor].
  final String cwd;

  /// Executable path for the provider binary.
  final String executable;

  /// Timeout applied to a single turn.
  final Duration turnTimeout;

  /// Provider-agnostic harness configuration forwarded during initialization.
  final HarnessLaunchOptions harnessConfig;

  /// Provider-specific options forwarded to the concrete harness.
  final Map<String, dynamic> providerOptions;

  /// Canonical tool names this spawn's step declared, and the roots its
  /// file-mutating tools may write.
  ///
  /// Set only for a workflow-step spawn. When present, the derived Claude
  /// permission rules become the spawn's total policy: the operator's
  /// user-scope settings are excluded, so a step runs on what it declared
  /// rather than on whatever the host's `~/.claude/settings.json` happens to
  /// allow. Null leaves today's behaviour, inheritance included.
  final List<String>? declaredCanonicalTools;
  final List<String> declaredWritableRoots;

  /// Environment variables visible to the provider subprocess.
  final Map<String, String> environment;

  /// Request-scoped variables visible only to a containerized provider subprocess.
  final Map<String, String> containerEnvironment;

  /// Optional process factory used by subprocess-backed harnesses.
  final ProcessFactory? processFactory;

  /// Platform policy forwarded to built-in subprocess harnesses.
  final PlatformCapabilities? platformCapabilities;

  /// Optional container manager used to spawn the harness in isolation.
  final ContainerExecutor? containerManager;

  /// Optional guard evaluation chain used by Claude harnesses.
  final GuardChain? guardChain;

  /// Optional guard audit logger used by Claude harnesses.
  final GuardAuditLogger? auditLogger;

  /// Exact DartClaw MCP tool names mapped to their guard semantic.
  final Map<String, CanonicalTool> ownMcpToolCanonicals;

  /// Memory apply callback used when the internal MCP server is not configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryApply;

  /// Memory observation callback used when the internal MCP server is not configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryObserve;

  /// Context-aware memory apply callback for direct SDK MCP calls.
  final ContextualMemoryToolHandler? onContextualMemoryApply;

  /// Context-aware memory observation callback for direct SDK MCP calls.
  final ContextualMemoryToolHandler? onContextualMemoryObserve;

  /// Memory search callback used when the internal MCP server is not configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemorySearch;

  /// Memory read callback used when the internal MCP server is not configured.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onMemoryRead;

  /// Callback fired when Claude Code's own permission layer denies a tool call.
  ///
  /// Wired in `HarnessWiring` to emit `ToolPermissionDeniedEvent` on the EventBus.
  final void Function(String toolName, String? reason)? onPermissionDenied;

  /// History replay configuration for Claude harnesses.
  final HistoryConfig historyConfig;

  /// Makes the DartClaw-dedicated subscription home usable before a host spawn
  /// and answers its path, or `null` when this deployment presents an API key.
  /// Wired in `HarnessWiring`, which owns the stores and the one refresh
  /// authority per store.
  final Future<String?> Function()? prepareSubscriptionHome;

  /// Creates an immutable harness-construction configuration.
  const new({
    required this.cwd,
    this.executable = 'claude',
    this.turnTimeout = const Duration(seconds: 1800),
    this.harnessConfig = const HarnessLaunchOptions(),
    this.historyConfig = const HistoryConfig.defaults(),
    this.providerOptions = const <String, dynamic>{},
    this.declaredCanonicalTools,
    this.declaredWritableRoots = const <String>[],
    this.environment = const <String, String>{},
    this.containerEnvironment = const <String, String>{},
    this.processFactory,
    this.platformCapabilities,
    this.containerManager,
    this.guardChain,
    this.auditLogger,
    this.ownMcpToolCanonicals = const {},
    this.onMemoryApply,
    this.onMemoryObserve,
    this.onContextualMemoryApply,
    this.onContextualMemoryObserve,
    this.onMemorySearch,
    this.onMemoryRead,
    this.onPermissionDenied,
    this.prepareSubscriptionHome,
  });
}

/// Factory for creating [AgentHarness] instances by provider identifier.
class HarnessFactory {
  static final _log = Logger('HarnessFactory');

  final Map<String, AgentHarness Function(HarnessFactoryConfig config)> _factories = {};
  final Set<String> _firstClaimedProviders = {};

  /// Cached probe instances used by [skillActivationLineFor]. Probes are
  /// stateless relative to skills — the activation line depends only on
  /// the harness type, not its construction config — so one instance per
  /// provider is enough to answer every prompt-build call in the
  /// long-lived factory.
  final Map<String, AgentHarness> _activationProbes = {};

  /// Creates a factory with built-in provider registrations.
  new() {
    register('claude', _createClaudeHarness);
    register('codex', _createCodexHarness);
  }

  /// Registers a provider-specific harness factory.
  ///
  /// Drops any cached probe for the same [providerId] so the next
  /// activation-line lookup reflects the new registration.
  void register(String providerId, AgentHarness Function(HarnessFactoryConfig config) factory) {
    _factories[providerId] = factory;
    _activationProbes.remove(providerId);
  }

  /// Registers the first extension claim for [providerId].
  ///
  /// Constructor-installed built-ins are defaults rather than registrar
  /// claims, so the first extension may replace one. Later extension claims
  /// are ignored to keep factory ownership aligned with the runtime's
  /// first-claim-wins provider, policy and credential lookups.
  void registerFirstClaim(String providerId, AgentHarness Function(HarnessFactoryConfig config) factory) {
    if (!_firstClaimedProviders.add(providerId)) return;
    register(providerId, factory);
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

  /// Returns which registered providers support session continuity.
  ///
  /// Creates lightweight, unstarted harness instances to probe their capability
  /// flags — no process is spawned. Useful for offline validation (e.g.,
  /// `workflow validate`) where a live execution coordinator is not available.
  Set<String> probeContinuityProviders() {
    final result = <String>{};
    for (final entry in _factories.entries) {
      final harness = entry.value(const HarnessFactoryConfig(cwd: '/'));
      if (harness.supportsSessionContinuity) {
        result.add(entry.key);
      }
    }
    return result;
  }

  /// Returns the skill-activation line for [providerId] via polymorphic
  /// dispatch — creates an unstarted lightweight harness instance and
  /// asks it. Falls back to the [AgentHarness] base-class default when the
  /// provider is not registered, so callers working with an unknown
  /// provider still get the portable verbose form.
  ///
  /// This is the entry point used by prompt builders that only have a
  /// provider name to go on. Keeps the activation-line decision
  /// owned by each harness — adding a new harness automatically lights
  /// up correct activation without any central switch to update.
  String skillActivationLineFor(String? providerId, String skill) {
    if (providerId == null) {
      return AgentHarness.defaultSkillActivationLine(skill);
    }
    final probe = _activationProbes[providerId];
    if (probe != null) return probe.skillActivationLine(skill);
    final factory = _factories[providerId];
    if (factory == null) {
      return AgentHarness.defaultSkillActivationLine(skill);
    }
    final created = factory(const HarnessFactoryConfig(cwd: '/'));
    _activationProbes[providerId] = created;
    return created.skillActivationLine(skill);
  }

  /// Warns when the factory has no registered providers — indicates that
  /// a caller constructed us outside the normal wiring path, which
  /// silently breaks provider lookup and skill-activation dispatch.
  void warnIfEmpty({String context = ''}) {
    if (_factories.isEmpty) {
      _log.warning(
        'HarnessFactory has no registered providers${context.isEmpty ? '' : ' ($context)'}; '
        'provider lookups and skill-activation dispatch will all fall back to defaults.',
      );
    }
  }
}

AgentHarness _createClaudeHarness(HarnessFactoryConfig config) {
  return ClaudeCodeHarness(
    claudeExecutable: config.executable,
    cwd: config.cwd,
    turnTimeout: config.turnTimeout,
    providerOptions: config.providerOptions,
    onMemoryApply: config.onMemoryApply,
    onMemoryObserve: config.onMemoryObserve,
    onContextualMemoryApply: config.onContextualMemoryApply,
    onContextualMemoryObserve: config.onContextualMemoryObserve,
    onMemorySearch: config.onMemorySearch,
    onMemoryRead: config.onMemoryRead,
    onPermissionDenied: config.onPermissionDenied,
    harnessConfig: config.harnessConfig,
    historyConfig: config.historyConfig,
    containerManager: config.containerManager,
    environment: config.environment,
    containerEnvironment: config.containerEnvironment,
    processFactory: config.processFactory,
    guardChain: config.guardChain,
    auditLogger: config.auditLogger,
    protocolAdapter: ClaudeProtocolAdapter(ownMcpToolCanonicals: config.ownMcpToolCanonicals),
    platformCapabilities: config.platformCapabilities,
    declaredCanonicalTools: config.declaredCanonicalTools,
    declaredWritableRoots: config.declaredWritableRoots,
  );
}

AgentHarness _createCodexHarness(HarnessFactoryConfig config) {
  return CodexHarness(
    cwd: config.cwd,
    executable: config.executable == 'claude' ? 'codex' : config.executable,
    turnTimeout: config.turnTimeout,
    environment: config.environment,
    containerEnvironment: config.containerEnvironment,
    processFactory: config.processFactory,
    harnessConfig: config.harnessConfig,
    providerOptions: config.providerOptions,
    guardChain: config.guardChain,
    adapter: CodexProtocolAdapter(ownMcpToolCanonicals: config.ownMcpToolCanonicals),
    platformCapabilities: config.platformCapabilities,
    containerManager: config.containerManager,
    prepareSubscriptionHome: config.prepareSubscriptionHome,
  );
}
