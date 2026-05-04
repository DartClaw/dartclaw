import 'dart:io';

import 'package:dartclaw_cli/src/commands/init/setup_apply.dart';
import 'package:dartclaw_cli/src/commands/init/setup_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

SetupState _state({
  String? instanceDir,
  String provider = 'claude',
  String authMethod = 'env',
  String? model = 'sonnet',
  int port = 3333,
  String gatewayAuthMode = 'token',
  String instanceName = 'TestBot',
  List<String>? providers,
  Map<String, String>? providerAuthMethods,
  Map<String, String>? providerModels,
}) {
  return SetupState(
    instanceName: instanceName,
    instanceDir: instanceDir ?? Directory.systemTemp.createTempSync('setup_apply_test_').path,
    provider: provider,
    authMethod: authMethod,
    model: model,
    providers: providers,
    providerAuthMethods: providerAuthMethods,
    providerModels: providerModels,
    port: port,
    gatewayAuthMode: gatewayAuthMode,
  );
}

void main() {
  late Directory tempDir;
  late SetupState state;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('setup_apply_test_');
    state = _state(instanceDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('SetupApply', () {
    test('writes instance name, primary provider, and model to config', () async {
      await SetupApply.apply(state);

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['name'], 'TestBot');
      expect(yaml['agent']['provider'], 'claude');
      expect(yaml['agent']['model'], 'sonnet');
      expect(yaml['data_dir'], tempDir.path);
    });

    test('writes per-provider config and indirect credentials', () async {
      final multi = _state(
        instanceDir: tempDir.path,
        provider: 'codex',
        authMethod: 'env',
        model: 'gpt-5',
        providers: const ['claude', 'codex'],
        providerAuthMethods: const {'claude': 'oauth', 'codex': 'env'},
        providerModels: const {'claude': 'haiku', 'codex': 'gpt-5'},
      );
      await SetupApply.apply(multi);

      final raw = File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync();
      final yaml = loadYaml(raw) as Map;
      expect(yaml['providers']['claude']['auth_method'], 'oauth');
      expect(yaml['providers']['claude']['model'], 'haiku');
      expect(yaml['providers']['codex']['auth_method'], 'env');
      expect(yaml['providers']['codex']['model'], 'gpt-5');
      expect(raw, contains(r'${CODEX_API_KEY}'));
    });

    test('writes supported channel keys under channels.*', () async {
      final fullTrack = SetupState(
        instanceName: 'T',
        instanceDir: tempDir.path,
        provider: 'claude',
        authMethod: 'oauth',
        model: 'sonnet',
        port: 3333,
        gatewayAuthMode: 'token',
        manageAdvancedSettings: true,
        whatsappEnabled: true,
        gowaExecutable: 'whatsapp',
        gowaPort: 3100,
        signalEnabled: true,
        signalPhoneNumber: '+12125550100',
        signalExecutable: 'signal-cli',
        googleChatEnabled: true,
        googleChatServiceAccount: '/etc/sa.json',
        googleChatAudienceType: 'project-number',
        googleChatAudience: '123456',
      );
      await SetupApply.apply(fullTrack);

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['channels']['whatsapp']['enabled'], isTrue);
      expect(yaml['channels']['signal']['enabled'], isTrue);
      expect(yaml['channels']['google_chat']['audience']['type'], 'project-number');
      expect(yaml['channels']['google_chat']['audience']['value'], '123456');
    });

    test('writes guard toggles through guards.*', () async {
      final guarded = SetupState(
        instanceName: 'T',
        instanceDir: tempDir.path,
        provider: 'claude',
        authMethod: 'oauth',
        model: 'sonnet',
        port: 3333,
        gatewayAuthMode: 'token',
        manageAdvancedSettings: true,
        contentGuardEnabled: false,
        inputSanitizerEnabled: false,
      );
      await SetupApply.apply(guarded);

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['guards']['content']['enabled'], isFalse);
      expect(yaml['guards']['input_sanitizer']['enabled'], isFalse);
    });

    test('rerun removes deselected providers, channels, container, and env credentials', () async {
      final initial = SetupState(
        instanceName: 'T',
        instanceDir: tempDir.path,
        provider: 'codex',
        authMethod: 'env',
        model: 'gpt-5',
        providers: const ['claude', 'codex'],
        providerAuthMethods: const {'claude': 'oauth', 'codex': 'env'},
        providerModels: const {'claude': 'sonnet', 'codex': 'gpt-5'},
        port: 3333,
        gatewayAuthMode: 'token',
        manageAdvancedSettings: true,
        whatsappEnabled: true,
        gowaExecutable: 'whatsapp',
        gowaPort: 3100,
        containerEnabled: true,
        containerImage: 'dartclaw-agent:v2',
        contentGuardEnabled: false,
        inputSanitizerEnabled: false,
      );
      await SetupApply.apply(initial);

      final rerun = SetupState(
        instanceName: 'T',
        instanceDir: tempDir.path,
        provider: 'claude',
        authMethod: 'oauth',
        model: 'sonnet',
        providers: const ['claude'],
        providerAuthMethods: const {'claude': 'oauth'},
        providerModels: const {'claude': 'sonnet'},
        port: 3333,
        gatewayAuthMode: 'token',
        manageAdvancedSettings: true,
        whatsappEnabled: false,
        containerEnabled: false,
        contentGuardEnabled: true,
        inputSanitizerEnabled: true,
      );
      await SetupApply.apply(rerun);

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['providers']['claude'], isNotNull);
      expect(yaml['providers']['codex'], isNull);
      expect(yaml['credentials']['openai'], isNull);
      expect(yaml['channels']['whatsapp'], isNull);
      expect(yaml['container'], isNull);
      expect(yaml['guards']['content']['enabled'], isTrue);
      expect(yaml['guards']['input_sanitizer']['enabled'], isTrue);
    });

    test('scaffolds workspace and onboarding files idempotently', () async {
      await SetupApply.apply(state);
      final created = await SetupApply.apply(state);

      expect(Directory(p.join(tempDir.path, 'workspace')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'workspace', 'AGENTS.md')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'workspace', 'ONBOARDING.md')).existsSync(), isTrue);
      expect(created.where((path) => path.endsWith('AGENTS.md')), isEmpty);
    });
  });
}
