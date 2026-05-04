import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_loader.dart';
import '../service/service_backend.dart';
import '../service/setup_verifier.dart';
import 'setup_apply.dart';
import 'setup_preflight.dart';
import 'setup_state.dart';

typedef _SetupDefaults = ({
  String instanceName,
  String instanceDir,
  List<String> providers,
  String primaryProvider,
  Map<String, String> authMethods,
  Map<String, String> models,
  int port,
  String gatewayAuthMode,
  bool whatsappEnabled,
  String? gowaExecutable,
  int? gowaPort,
  bool signalEnabled,
  String? signalPhoneNumber,
  String? signalExecutable,
  bool googleChatEnabled,
  String? googleChatServiceAccount,
  String? googleChatAudienceType,
  String? googleChatAudience,
  bool containerEnabled,
  String? containerImage,
  bool contentGuardEnabled,
  bool inputSanitizerEnabled,
});

abstract class _InitImpl extends Command<void> {
  @override
  String get description => 'Set up a DartClaw instance (config, workspace scaffold, onboarding)';

  final Logger _logger;
  final Future<SetupPreflight> Function({
    required List<String> providers,
    required int port,
    required String instanceDir,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
  })
  _runPreflight;
  final Future<List<String>> Function(SetupState) _applySetup;
  final void Function(String) _writeLine;
  final bool Function() _hasTerminal;
  final DartclawConfig? Function(String? configPath) _loadConfig;
  final SetupVerifier _verifier;
  final ServiceBackend? _serviceBackend;

  _InitImpl({
    Logger? logger,
    Future<SetupPreflight> Function({
      required List<String> providers,
      required int port,
      required String instanceDir,
      Future<ProcessResult> Function(String, List<String>)? runProcess,
    })?
    runPreflight,
    Future<List<String>> Function(SetupState)? applySetup,
    void Function(String)? writeLine,
    bool Function()? hasTerminal,
    DartclawConfig? Function(String? configPath)? loadConfig,
    SetupVerifier? verifier,
    ServiceBackend? serviceBackend,
  }) : _logger = logger ?? Logger(),
       _runPreflight = runPreflight ?? SetupPreflight.run,
       _applySetup = applySetup ?? SetupApply.apply,
       _writeLine = writeLine ?? stdout.writeln,
       _hasTerminal = hasTerminal ?? (() => stdout.hasTerminal),
       _loadConfig = loadConfig ?? _defaultLoadConfig,
       _verifier = verifier ?? SetupVerifier(),
       _serviceBackend = serviceBackend {
    argParser
      ..addFlag(
        'non-interactive',
        abbr: 'n',
        help: 'Run without prompts; all required inputs must be provided or already present in config',
        negatable: false,
      )
      ..addOption('instance-name', help: 'Human-readable name for this instance', defaultsTo: 'DartClaw')
      ..addOption('instance-dir', help: 'Directory for config and runtime artifacts', valueHelp: 'path')
      ..addMultiOption(
        'provider',
        allowed: ['claude', 'codex'],
        allowedHelp: {'claude': 'Anthropic Claude via claude CLI', 'codex': 'OpenAI Codex via codex CLI'},
        help: 'Configure one or more providers',
      )
      ..addOption(
        'primary-provider',
        allowed: ['claude', 'codex'],
        help: 'Primary provider used by default when multiple providers are configured',
      )
      ..addOption(
        'auth-method',
        allowed: ['env', 'oauth'],
        allowedHelp: {'env': 'API key from environment variable', 'oauth': "Use provider binary's own auth"},
        help: 'Legacy single-provider auth method shortcut',
      )
      ..addOption('auth-claude', allowed: ['env', 'oauth'], help: 'Claude auth method')
      ..addOption('auth-codex', allowed: ['env', 'oauth'], help: 'Codex auth method')
      ..addOption('model-claude', help: 'Claude model (haiku, sonnet, opus)')
      ..addOption('model-codex', help: 'Codex model')
      ..addOption('port', abbr: 'p', help: 'Port for the HTTP server', valueHelp: 'N')
      ..addOption(
        'gateway-auth',
        allowed: ['token', 'none'],
        allowedHelp: {'token': 'Require bearer token for HTTP access', 'none': 'No HTTP authentication'},
        help: 'Gateway authentication mode',
        defaultsTo: 'token',
      )
      ..addFlag(
        'skip-verify',
        help: 'Skip provider verification after setup (yields configured-but-unverified outcome)',
        negatable: false,
      )
      ..addOption(
        'launch',
        allowed: ['foreground', 'background', 'service', 'skip'],
        allowedHelp: {
          'foreground': 'Start server in foreground (dartclaw serve)',
          'background': 'Start server in background',
          'service': 'Install and start as user-scoped service',
          'skip': 'Do not start the server',
        },
        help: 'What to do after setup completes',
        defaultsTo: 'skip',
      )
      ..addOption(
        'track',
        allowed: ['quick', 'full'],
        allowedHelp: {
          'quick': 'Quick track — core options only (default)',
          'full': 'Full track — channels + advanced runtime options',
        },
        help: 'Setup depth',
        defaultsTo: 'quick',
      )
      ..addFlag('whatsapp', help: 'Enable WhatsApp channel (Full track)')
      ..addOption('gowa-executable', help: 'GOWA sidecar binary name or path', valueHelp: 'name')
      ..addOption('gowa-port', help: 'GOWA HTTP API port', valueHelp: 'N')
      ..addFlag('signal', help: 'Enable Signal channel (Full track)')
      ..addOption('signal-phone', help: 'Phone number registered with signal-cli', valueHelp: 'number')
      ..addOption('signal-executable', help: 'signal-cli binary name or path', valueHelp: 'name')
      ..addFlag('google-chat', help: 'Enable Google Chat channel (Full track)')
      ..addOption('google-chat-service-account', help: 'Path to service-account JSON', valueHelp: 'path')
      ..addOption(
        'google-chat-audience-type',
        allowed: ['app-url', 'project-number'],
        help: 'Google Chat JWT audience type',
        defaultsTo: 'app-url',
      )
      ..addOption('google-chat-audience', help: 'Google Chat JWT audience value', valueHelp: 'value')
      ..addFlag('container', help: 'Enable Docker container isolation (Full track)')
      ..addOption('container-image', help: 'Docker image for isolated agent execution', valueHelp: 'image')
      ..addFlag('no-content-guard', help: 'Disable content guard (Full track; not recommended)', negatable: false)
      ..addFlag('no-input-sanitizer', help: 'Disable input sanitizer (Full track; not recommended)', negatable: false);
  }

  @override
  Future<void> run() async {
    final nonInteractive = argResults!['non-interactive'] as bool;
    final isTerminal = _hasTerminal();
    final explicitConfigPath = _globalConfigPath();
    final existingConfig = _loadExistingConfig(explicitConfigPath);

    if (!isTerminal && !nonInteractive) {
      _writeLine('No terminal detected - running in non-interactive mode.');
    }

    final state = nonInteractive || !isTerminal ? _resolveFromFlags(existingConfig) : await _runWizard(existingConfig);

    var launch = argResults!['launch'] as String;
    if (!nonInteractive && isTerminal && !argResults!.wasParsed('launch')) {
      launch = _logger.chooseOne<String>(
        'Launch after setup',
        choices: ['skip', 'foreground', 'background', 'service'],
        defaultValue: launch,
        display: (value) => switch (value) {
          'foreground' => 'foreground  (start now in this terminal)',
          'background' => 'background  (start detached)',
          'service' => 'service     (install + start background service)',
          _ => 'skip        (configure only)',
        },
      );
      _writeLine('');
    }

    final preflight = await _runPreflight(providers: state.providers, port: state.port, instanceDir: state.instanceDir);

    if (!preflight.passed) {
      for (final error in preflight.errors) {
        _logger.err(error);
      }
      throw UsageException('Setup preflight failed — fix the issues above and re-run.', usage);
    }

    for (final warning in preflight.warnings) {
      _logger.warn(warning);
    }

    final applyProgress = isTerminal ? _logger.progress('Applying setup') : null;
    final List<String> created;
    try {
      created = await _applySetup(state);
      applyProgress?.complete('Done');
    } catch (error) {
      applyProgress?.fail('Setup failed');
      rethrow;
    }

    _writeLine('');
    _writeLine('DartClaw instance ready at: ${state.instanceDir}');
    for (final file in created) {
      _writeLine('  $file');
    }

    _printDeferredNextSteps(state);

    final configPath = state.configPath;
    final verifyProgress = isTerminal ? _logger.progress('Verifying configuration') : null;
    final verification = await _verifier.verify(
      configPath: configPath,
      providerIds: state.providers,
      instanceDir: state.instanceDir,
      port: state.port,
      skipNetwork: argResults!['skip-verify'] as bool,
    );
    verifyProgress?.complete('Done');

    if (verification.failed) {
      for (final failure in verification.local.failures) {
        _logger.err(failure);
      }
      throw UsageException('Post-setup verification failed — fix the issues above.', usage);
    }

    for (final warning in verification.local.warnings) {
      _logger.warn(warning);
    }

    _writeLine('');
    if (verification.configuredButUnverified) {
      _writeLine('Status: configured but unverified');
      if (verification.network?.message != null) {
        _writeLine('  ${verification.network!.message}');
      }
    } else {
      _writeLine('Status: verified');
    }

    await _handleLaunch(launch, state);
  }

  String _requireAuthMethod(Map<String, String> authMethods, String primaryProvider) {
    final authMethod = authMethods[primaryProvider];
    if (authMethod != null && authMethod.isNotEmpty) {
      return authMethod;
    }

    throw UsageException(
      'Missing auth method for primary provider "$primaryProvider". '
      'Provide --auth-$primaryProvider or re-run in an interactive terminal.',
      usage,
    );
  }

  Future<void> _handleLaunch(String launch, SetupState state) async {
    final configPath = state.configPath;
    final binPath = await _resolveBinPath();
    final sourceDir = _detectSourceDir();

    switch (launch) {
      case 'foreground':
        _writeLine('');
        _writeLine('Starting server in foreground...');
        _writeLine('Press Ctrl+C to stop.');
        final result = await Process.start(binPath, [
          'serve',
          '--config',
          configPath,
          if (sourceDir != null) ...['--source-dir', sourceDir],
        ], mode: ProcessStartMode.inheritStdio);
        exitCode = await result.exitCode;
        return;

      case 'background':
        _writeLine('');
        _writeLine('Starting server in background...');
        await Process.start(binPath, [
          'serve',
          '--config',
          configPath,
          if (sourceDir != null) ...['--source-dir', sourceDir],
        ], mode: ProcessStartMode.detached);
        _writeLine('Server started. Logs: ${state.instanceDir}/logs/');
        return;

      case 'service':
        _writeLine('');
        _writeLine('Installing service...');
        final backend = _serviceBackend ?? createPlatformBackend();
        final installResult = await backend.install(
          binPath: binPath,
          configPath: configPath,
          port: state.port,
          instanceDir: state.instanceDir,
          sourceDir: sourceDir,
        );
        if (installResult.success) {
          final startResult = await backend.start(instanceDir: state.instanceDir);
          _writeLine(
            startResult.success
                ? 'Service installed and started.'
                : 'Service installed; start manually: dartclaw service start --instance-dir ${state.instanceDir}',
          );
        } else {
          _logger.warn('Service install failed: ${installResult.message}');
          _writeLine('Start manually: dartclaw serve --config $configPath');
        }
        return;

      case 'skip':
      default:
        _writeLine('');
        _writeLine('Start the server: dartclaw serve --config $configPath');
        return;
    }
  }

  SetupState _resolveFromFlags(DartclawConfig? existingConfig) {
    final defaults = _defaultsFromExisting(existingConfig);
    final explicitConfigPath = _globalConfigPath();
    final selectedProviders = ((argResults!['provider'] as List<String>?) ?? const <String>[]).toSet().toList(
      growable: false,
    );
    final providers = selectedProviders.isEmpty ? defaults.providers : selectedProviders;
    final primaryProvider =
        (argResults!['primary-provider'] as String?) ??
        (providers.length == 1
            ? providers.single
            : providers.contains(defaults.primaryProvider)
            ? defaults.primaryProvider
            : '');

    final authMethods = <String, String>{};
    final models = <String, String>{};
    final missing = <String>[];
    final strictNonInteractive = argResults!['non-interactive'] as bool;

    for (final provider in providers) {
      final authMethod =
          _providerAuthOption(provider) ??
          (providers.length == 1 ? argResults!['auth-method'] as String? : null) ??
          defaults.authMethods[provider];
      if (authMethod == null || authMethod.isEmpty) {
        if (strictNonInteractive) {
          missing.add('--auth-$provider');
        }
      } else {
        authMethods[provider] = authMethod;
      }

      final model = _providerModelOption(provider) ?? defaults.models[provider];
      if (model == null || model.trim().isEmpty) {
        if (strictNonInteractive) {
          missing.add('--model-$provider');
        }
      } else {
        models[provider] = model.trim();
      }
    }

    if (strictNonInteractive) {
      if (providers.isEmpty) {
        missing.add('--provider');
      }
      if (providers.length > 1 && primaryProvider.isEmpty) {
        missing.add('--primary-provider');
      }
      if (missing.isNotEmpty) {
        throw UsageException('Missing required inputs in --non-interactive mode: ${missing.join(', ')}', usage);
      }
    }

    if (providers.isEmpty) {
      throw UsageException('Select at least one provider.', usage);
    }
    if (!providers.contains(primaryProvider)) {
      throw UsageException('--primary-provider must match one of the selected providers.', usage);
    }

    final port = _resolvePort(defaults.port);
    final instanceName = argResults!.wasParsed('instance-name')
        ? argResults!['instance-name'] as String
        : defaults.instanceName;
    final instanceDir = argResults!.wasParsed('instance-dir')
        ? argResults!['instance-dir'] as String
        : defaults.instanceDir;
    final configPath =
        explicitConfigPath ?? resolveCliConfigPath(configPath: null, env: {'DARTCLAW_HOME': instanceDir});
    final gatewayAuthMode = argResults!.wasParsed('gateway-auth')
        ? argResults!['gateway-auth'] as String
        : defaults.gatewayAuthMode;
    final manageAdvancedSettings =
        (argResults!['track'] as String) == 'full' ||
        const [
          'whatsapp',
          'gowa-executable',
          'gowa-port',
          'signal',
          'signal-phone',
          'signal-executable',
          'google-chat',
          'google-chat-service-account',
          'google-chat-audience-type',
          'google-chat-audience',
          'container',
          'container-image',
          'no-content-guard',
          'no-input-sanitizer',
        ].any(argResults!.wasParsed);

    final gowaPortArg = argResults!['gowa-port'] as String?;
    final gowaPort = gowaPortArg != null ? int.tryParse(gowaPortArg) : defaults.gowaPort;

    return SetupState(
      instanceName: instanceName,
      instanceDir: instanceDir,
      configPath: configPath,
      provider: primaryProvider,
      authMethod: _requireAuthMethod(authMethods, primaryProvider),
      model: models[primaryProvider],
      providers: providers,
      providerAuthMethods: authMethods,
      providerModels: models,
      port: port,
      gatewayAuthMode: gatewayAuthMode,
      manageAdvancedSettings: manageAdvancedSettings,
      whatsappEnabled: argResults!.wasParsed('whatsapp') ? argResults!['whatsapp'] as bool : defaults.whatsappEnabled,
      gowaExecutable: argResults!.wasParsed('gowa-executable')
          ? argResults!['gowa-executable'] as String?
          : defaults.gowaExecutable,
      gowaPort: gowaPort,
      signalEnabled: argResults!.wasParsed('signal') ? argResults!['signal'] as bool : defaults.signalEnabled,
      signalPhoneNumber: argResults!.wasParsed('signal-phone')
          ? argResults!['signal-phone'] as String?
          : defaults.signalPhoneNumber,
      signalExecutable: argResults!.wasParsed('signal-executable')
          ? argResults!['signal-executable'] as String?
          : defaults.signalExecutable,
      googleChatEnabled: argResults!.wasParsed('google-chat')
          ? argResults!['google-chat'] as bool
          : defaults.googleChatEnabled,
      googleChatServiceAccount: argResults!.wasParsed('google-chat-service-account')
          ? argResults!['google-chat-service-account'] as String?
          : defaults.googleChatServiceAccount,
      googleChatAudienceType: argResults!.wasParsed('google-chat-audience-type')
          ? argResults!['google-chat-audience-type'] as String?
          : defaults.googleChatAudienceType,
      googleChatAudience: argResults!.wasParsed('google-chat-audience')
          ? argResults!['google-chat-audience'] as String?
          : defaults.googleChatAudience,
      containerEnabled: argResults!.wasParsed('container')
          ? argResults!['container'] as bool
          : defaults.containerEnabled,
      containerImage: argResults!.wasParsed('container-image')
          ? argResults!['container-image'] as String?
          : defaults.containerImage,
      contentGuardEnabled: argResults!.wasParsed('no-content-guard') ? false : defaults.contentGuardEnabled,
      inputSanitizerEnabled: argResults!.wasParsed('no-input-sanitizer') ? false : defaults.inputSanitizerEnabled,
    );
  }

  Future<SetupState> _runWizard(DartclawConfig? existingConfig) async {
    final defaults = _defaultsFromExisting(existingConfig);
    final explicitConfigPath = _globalConfigPath();

    _writeLine('');
    _writeLine('DartClaw Setup');
    _writeLine('──────────────');
    _writeLine('Quick-track wizard. Press Enter to accept defaults shown in (parentheses).');
    _writeLine('');

    final instanceName = _logger.prompt(
      'Instance name',
      defaultValue: argResults!.wasParsed('instance-name')
          ? argResults!['instance-name'] as String
          : defaults.instanceName,
    );
    final instanceDir = _logger.prompt(
      'Instance directory',
      defaultValue: argResults!.wasParsed('instance-dir')
          ? argResults!['instance-dir'] as String
          : defaults.instanceDir,
    );

    final preselectedProviders = ((argResults!['provider'] as List<String>?) ?? const <String>[]).toSet().toList(
      growable: false,
    );
    final selectedDefaults = preselectedProviders.isEmpty ? defaults.providers : preselectedProviders;

    late bool claudeEnabled;
    late bool codexEnabled;
    while (true) {
      claudeEnabled = _logger.confirm('Enable Claude provider?', defaultValue: selectedDefaults.contains('claude'));
      codexEnabled = _logger.confirm('Enable Codex provider?', defaultValue: selectedDefaults.contains('codex'));
      if (claudeEnabled || codexEnabled) {
        break;
      }
      _logger.err('Select at least one provider.');
    }

    final providers = <String>[if (claudeEnabled) 'claude', if (codexEnabled) 'codex'];
    final authMethods = <String, String>{};
    final models = <String, String>{};

    if (claudeEnabled) {
      authMethods['claude'] = _logger.chooseOne<String>(
        'Claude auth method',
        choices: ['oauth', 'env'],
        defaultValue: _providerArgOrDefault('claude', defaults.authMethods['claude'] ?? 'oauth'),
        display: (value) => value == 'oauth' ? 'oauth  (use claude CLI login)' : 'env    (read ANTHROPIC_API_KEY)',
      );
      models['claude'] = _logger.chooseOne<String>(
        'Claude model',
        choices: ['opus', 'sonnet', 'haiku'],
        defaultValue: _providerModelOption('claude') ?? defaults.models['claude'] ?? 'sonnet',
      );
    }

    if (codexEnabled) {
      authMethods['codex'] = _logger.chooseOne<String>(
        'Codex auth method',
        choices: ['oauth', 'env'],
        defaultValue: _providerArgOrDefault('codex', defaults.authMethods['codex'] ?? 'oauth'),
        display: (value) => value == 'oauth' ? 'oauth  (use codex login)' : 'env    (read CODEX_API_KEY)',
      );
      models['codex'] = _logger
          .prompt('Codex model', defaultValue: _providerModelOption('codex') ?? defaults.models['codex'] ?? 'gpt-5')
          .trim();
    }

    final primaryProvider = providers.length == 1
        ? providers.single
        : _logger.chooseOne<String>(
            'Primary provider',
            choices: providers,
            defaultValue: providers.contains(defaults.primaryProvider) ? defaults.primaryProvider : providers.first,
          );

    final port = await _promptPort(initial: _resolvePort(defaults.port));
    final gatewayAuthMode = _logger.chooseOne<String>(
      'HTTP gateway auth',
      choices: ['token', 'none'],
      defaultValue: argResults!.wasParsed('gateway-auth')
          ? argResults!['gateway-auth'] as String
          : defaults.gatewayAuthMode,
      display: (value) => value == 'token' ? 'token  (require bearer token)' : 'none   (no HTTP authentication)',
    );
    final track = _logger.chooseOne<String>(
      'Setup depth',
      choices: ['quick', 'full'],
      defaultValue: argResults!['track'] as String,
      display: (value) =>
          value == 'quick' ? 'quick  (core options only)' : 'full   (channels + advanced runtime options)',
    );
    _writeLine('');

    if (track == 'quick') {
      return SetupState(
        instanceName: instanceName,
        instanceDir: instanceDir,
        configPath: explicitConfigPath,
        provider: primaryProvider,
        authMethod: _requireAuthMethod(authMethods, primaryProvider),
        model: models[primaryProvider],
        providers: providers,
        providerAuthMethods: authMethods,
        providerModels: models,
        port: port,
        gatewayAuthMode: gatewayAuthMode,
      );
    }

    return _runFullTrackWizard(
      instanceName: instanceName,
      instanceDir: instanceDir,
      providers: providers,
      primaryProvider: primaryProvider,
      authMethods: authMethods,
      models: models,
      port: port,
      gatewayAuthMode: gatewayAuthMode,
      configPath: explicitConfigPath,
      defaults: defaults,
    );
  }

  Future<SetupState> _runFullTrackWizard({
    required String instanceName,
    required String instanceDir,
    String? configPath,
    required List<String> providers,
    required String primaryProvider,
    required Map<String, String> authMethods,
    required Map<String, String> models,
    required int port,
    required String gatewayAuthMode,
    required _SetupDefaults defaults,
  }) async {
    _writeLine('Full-track setup — channels and advanced options.');
    _writeLine('Press Enter to accept defaults. Pairing and linking steps are deferred until after setup.');
    _writeLine('');

    final whatsappEnabled = _logger.confirm(
      'Enable WhatsApp channel?',
      defaultValue: argResults!.wasParsed('whatsapp') ? argResults!['whatsapp'] as bool : defaults.whatsappEnabled,
    );
    String? gowaExecutable;
    int? gowaPort;
    if (whatsappEnabled) {
      gowaExecutable = _logger.prompt(
        '  GOWA sidecar executable',
        defaultValue: argResults!['gowa-executable'] as String? ?? defaults.gowaExecutable ?? 'whatsapp',
      );
      final gowaPortStr = _logger.prompt(
        '  GOWA HTTP API port',
        defaultValue: argResults!['gowa-port'] as String? ?? '${defaults.gowaPort ?? 3000}',
      );
      gowaPort = int.tryParse(gowaPortStr.trim()) ?? 3000;
      _writeLine('');
    }

    final signalEnabled = _logger.confirm(
      'Enable Signal channel?',
      defaultValue: argResults!.wasParsed('signal') ? argResults!['signal'] as bool : defaults.signalEnabled,
    );
    String? signalPhoneNumber;
    String? signalExecutable;
    if (signalEnabled) {
      signalPhoneNumber = _logger.prompt(
        '  Phone number',
        defaultValue: argResults!['signal-phone'] as String? ?? defaults.signalPhoneNumber ?? '',
      );
      signalExecutable = _logger.prompt(
        '  signal-cli executable',
        defaultValue: argResults!['signal-executable'] as String? ?? defaults.signalExecutable ?? 'signal-cli',
      );
      _writeLine('');
    }

    final googleChatEnabled = _logger.confirm(
      'Enable Google Chat channel?',
      defaultValue: argResults!.wasParsed('google-chat')
          ? argResults!['google-chat'] as bool
          : defaults.googleChatEnabled,
    );
    String? googleChatServiceAccount;
    String? googleChatAudienceType;
    String? googleChatAudience;
    if (googleChatEnabled) {
      googleChatServiceAccount = _logger.prompt(
        '  Service-account JSON path',
        defaultValue: argResults!['google-chat-service-account'] as String? ?? defaults.googleChatServiceAccount ?? '',
      );
      googleChatAudienceType = _logger.chooseOne<String>(
        '  JWT audience type',
        choices: ['app-url', 'project-number'],
        defaultValue:
            argResults!['google-chat-audience-type'] as String? ?? defaults.googleChatAudienceType ?? 'app-url',
      );
      googleChatAudience = _logger.prompt(
        '  JWT audience value',
        defaultValue: argResults!['google-chat-audience'] as String? ?? defaults.googleChatAudience ?? '',
      );
      _writeLine('');
    }

    final containerEnabled = _logger.confirm(
      'Enable Docker container isolation?',
      defaultValue: argResults!.wasParsed('container') ? argResults!['container'] as bool : defaults.containerEnabled,
    );
    String? containerImage;
    if (containerEnabled) {
      containerImage = _logger.prompt(
        '  Docker image',
        defaultValue: argResults!['container-image'] as String? ?? defaults.containerImage ?? 'dartclaw-agent:latest',
      );
    }

    final contentGuardEnabled = !(argResults!['no-content-guard'] as bool)
        ? _logger.confirm('Enable content guard?', defaultValue: defaults.contentGuardEnabled)
        : false;
    final inputSanitizerEnabled = !(argResults!['no-input-sanitizer'] as bool)
        ? _logger.confirm('Enable input sanitizer?', defaultValue: defaults.inputSanitizerEnabled)
        : false;
    if (!contentGuardEnabled) {
      _logger.warn('Content guard disabled — not recommended for channel deployments.');
    }
    if (!inputSanitizerEnabled) {
      _logger.warn('Input sanitizer disabled — not recommended for channel deployments.');
    }

    _writeLine('');

    return SetupState(
      instanceName: instanceName,
      instanceDir: instanceDir,
      configPath: configPath,
      provider: primaryProvider,
      authMethod: _requireAuthMethod(authMethods, primaryProvider),
      model: models[primaryProvider],
      providers: providers,
      providerAuthMethods: authMethods,
      providerModels: models,
      port: port,
      gatewayAuthMode: gatewayAuthMode,
      manageAdvancedSettings: true,
      whatsappEnabled: whatsappEnabled,
      gowaExecutable: gowaExecutable,
      gowaPort: gowaPort,
      signalEnabled: signalEnabled,
      signalPhoneNumber: signalPhoneNumber,
      signalExecutable: signalExecutable,
      googleChatEnabled: googleChatEnabled,
      googleChatServiceAccount: googleChatServiceAccount,
      googleChatAudienceType: googleChatAudienceType,
      googleChatAudience: googleChatAudience,
      containerEnabled: containerEnabled,
      containerImage: containerImage,
      contentGuardEnabled: contentGuardEnabled,
      inputSanitizerEnabled: inputSanitizerEnabled,
    );
  }

  Future<int> _promptPort({required int initial}) async {
    var candidate = initial;
    while (true) {
      final input = _logger.prompt('HTTP server port', defaultValue: '$candidate');
      final parsed = int.tryParse(input.trim());
      if (parsed == null || parsed < 1 || parsed > 65535) {
        _logger.err('Invalid port: $input — enter a number between 1 and 65535.');
        continue;
      }
      if (await _portInUse(parsed)) {
        final next = parsed + 1;
        _logger.warn('Port $parsed is already in use. Try $next?');
        candidate = next;
        continue;
      }
      return parsed;
    }
  }

  Future<bool> _portInUse(int port) async {
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      return false;
    } on SocketException {
      return true;
    } finally {
      await socket?.close();
    }
  }

  _SetupDefaults _defaultsFromExisting(DartclawConfig? existingConfig) {
    final instanceName = existingConfig?.server.name ?? 'DartClaw';
    final instanceDir = existingConfig?.server.dataDir ?? defaultInstanceDir();
    final providers = existingConfig != null && existingConfig.providers.entries.isNotEmpty
        ? existingConfig.providers.entries.keys.toList(growable: false)
        : [existingConfig?.agent.provider ?? 'claude'];
    final primaryProvider = providers.contains(existingConfig?.agent.provider)
        ? existingConfig!.agent.provider
        : providers.first;
    final authMethods = <String, String>{};
    final models = <String, String>{};

    for (final provider in providers) {
      final entry = existingConfig?.providers[provider];
      final optionAuth = entry?.options['auth_method'];
      final optionModel = entry?.options['model'];

      if (optionAuth is String && optionAuth.isNotEmpty) {
        authMethods[provider] = optionAuth;
      } else {
        authMethods[provider] = _defaultAuthMethodFor(existingConfig, provider);
      }

      if (provider == (existingConfig?.agent.provider ?? primaryProvider)) {
        final primaryModel = existingConfig?.agent.model;
        if (primaryModel != null && primaryModel.isNotEmpty) {
          models[provider] = primaryModel;
        }
      }
      if (!models.containsKey(provider) && optionModel is String && optionModel.isNotEmpty) {
        models[provider] = optionModel;
      }
    }

    final whatsapp = existingConfig?.channels.channelConfigs['whatsapp'];
    final signal = existingConfig?.channels.channelConfigs['signal'];
    final googleChat = existingConfig?.channels.channelConfigs['google_chat'];
    final googleChatAudience = googleChat?['audience'];

    return (
      instanceName: instanceName,
      instanceDir: instanceDir,
      providers: providers,
      primaryProvider: primaryProvider,
      authMethods: authMethods,
      models: models,
      port: existingConfig?.server.port ?? 3333,
      gatewayAuthMode: existingConfig?.gateway.authMode ?? 'token',
      whatsappEnabled: whatsapp?['enabled'] == true,
      gowaExecutable: whatsapp?['gowa_executable'] as String?,
      gowaPort: whatsapp?['gowa_port'] as int?,
      signalEnabled: signal?['enabled'] == true,
      signalPhoneNumber: signal?['phone_number'] as String?,
      signalExecutable: signal?['executable'] as String?,
      googleChatEnabled: googleChat?['enabled'] == true,
      googleChatServiceAccount: googleChat?['service_account'] as String?,
      googleChatAudienceType: googleChatAudience is Map ? googleChatAudience['type'] as String? : null,
      googleChatAudience: googleChatAudience is Map ? googleChatAudience['value'] as String? : null,
      containerEnabled: existingConfig?.container.enabled ?? false,
      containerImage: existingConfig?.container.image,
      contentGuardEnabled: existingConfig?.security.contentGuardEnabled ?? true,
      inputSanitizerEnabled: existingConfig?.security.inputSanitizerEnabled ?? true,
    );
  }

  String _defaultAuthMethodFor(DartclawConfig? config, String provider) {
    final credentialName = provider == 'codex' ? 'openai' : 'anthropic';
    final credential = config?.credentials[credentialName];
    return credential != null && credential.isPresent ? 'env' : 'oauth';
  }

  String? _providerAuthOption(String provider) {
    return switch (provider) {
      'codex' => argResults!['auth-codex'] as String?,
      _ => argResults!['auth-claude'] as String?,
    };
  }

  String _providerArgOrDefault(String provider, String fallback) {
    return _providerAuthOption(provider) ?? fallback;
  }

  String? _providerModelOption(String provider) {
    return switch (provider) {
      'codex' => argResults!['model-codex'] as String?,
      _ => argResults!['model-claude'] as String?,
    };
  }

  int _resolvePort(int fallback) {
    final portArg = argResults!['port'] as String?;
    if (portArg == null) {
      return fallback;
    }
    final parsed = int.tryParse(portArg);
    if (parsed == null || parsed < 1 || parsed > 65535) {
      throw UsageException('Invalid --port value: $portArg (must be 1–65535)', usage);
    }
    return parsed;
  }

  void _printDeferredNextSteps(SetupState state) {
    final lines = <String>[
      if (state.whatsappEnabled) 'WhatsApp pairing: start the server, then scan the QR code shown in the logs.',
      if (state.signalEnabled)
        'Signal linking: run `signal-cli link --name dartclaw` after the server is up, then restart DartClaw.',
      if (state.googleChatEnabled)
        'Google Chat: register the webhook after startup at http://host:${state.port}/integrations/googlechat.',
    ];
    if (lines.isEmpty) {
      return;
    }

    _writeLine('');
    _writeLine('Next steps still required:');
    for (final line in lines) {
      _writeLine('  - $line');
    }
  }

  DartclawConfig? _loadExistingConfig(String? configPath) => _loadConfig(configPath);

  String? _globalConfigPath() {
    final results = globalResults;
    if (results == null) {
      return null;
    }
    try {
      return results['config'] as String?;
    } on ArgumentError {
      return null;
    }
  }

  static DartclawConfig? _defaultLoadConfig(String? configPath) {
    try {
      return loadCliConfig(configPath: configPath);
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveBinPath() async {
    final command = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await Process.run(command, ['dartclaw']);
      if (result.exitCode == 0) {
        final resolved = result.stdout.toString().trim();
        if (resolved.isNotEmpty) {
          return resolved.split('\n').first.trim();
        }
      }
    } catch (_) {}
    return 'dartclaw';
  }

  String? _detectSourceDir() {
    final cwd = Directory.current.path;
    if (Directory('$cwd/packages/dartclaw_server/lib/src/templates').existsSync() &&
        Directory('$cwd/packages/dartclaw_server/lib/src/static').existsSync()) {
      return cwd;
    }
    return null;
  }
}

class InitCommand extends _InitImpl {
  @override
  String get name => 'init';

  InitCommand({
    super.logger,
    super.runPreflight,
    super.applySetup,
    super.writeLine,
    super.hasTerminal,
    super.loadConfig,
    super.verifier,
    super.serviceBackend,
  });
}

class SetupAliasCommand extends _InitImpl {
  @override
  String get name => 'setup';

  SetupAliasCommand({
    super.logger,
    super.runPreflight,
    super.applySetup,
    super.writeLine,
    super.hasTerminal,
    super.loadConfig,
    super.verifier,
    super.serviceBackend,
  });

  @override
  Future<void> run() async {
    stderr.writeln(
      'Note: "dartclaw setup" is an alias for "dartclaw init". '
      'Use "dartclaw init" going forward.',
    );
    await super.run();
  }
}
