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
  bool workflowTrack = false,
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
    workflowTrack: workflowTrack,
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

    test('workflow track keeps data_dir relative to the config folder', () async {
      await SetupApply.apply(_state(instanceDir: tempDir.path, workflowTrack: true));

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['data_dir'], '.');
      expect(File(p.join(tempDir.path, '.dartclaw-workflow-config')).existsSync(), isFalse);
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
      expect(File(p.join(tempDir.path, 'workspace', 'wiki', 'README.md')).existsSync(), isTrue);
      expect(created.where((path) => path.endsWith('AGENTS.md')), isEmpty);
    });

    test('onboarding template names structured USER sections, rerun command, and draft semantics', () async {
      await SetupApply.apply(state);

      final onboarding = File(p.join(tempDir.path, 'workspace', 'ONBOARDING.md')).readAsStringSync();
      for (final section in SetupApply.canonicalUserSections) {
        expect(onboarding, contains(section));
      }
      expect(onboarding, contains('dartclaw init --personalize'));
      expect(onboarding, contains('skip'));
      expect(onboarding, contains('later'));
      expect(onboarding, contains('.draft'));
    });

    test('personalize re-seeds onboarding without overwriting curated behavior files', () async {
      await SetupApply.apply(state);
      final userFile = File(p.join(tempDir.path, 'workspace', 'USER.md'))..writeAsStringSync('curated user');
      final soulFile = File(p.join(tempDir.path, 'workspace', 'SOUL.md'))..writeAsStringSync('curated soul');
      File(p.join(tempDir.path, 'workspace', 'ONBOARDING.md')).deleteSync();

      await SetupApply.personalize(state);

      expect(userFile.readAsStringSync(), 'curated user');
      expect(soulFile.readAsStringSync(), 'curated soul');
      final onboarding = File(p.join(tempDir.path, 'workspace', 'ONBOARDING.md')).readAsStringSync();
      expect(onboarding, contains('Rerun: true'));
      expect(onboarding, contains('USER.md.draft'));
      expect(onboarding, contains('SOUL.md.draft'));
    });

    test('applyDrafts merges canonical USER sections and replaces SOUL after confirmation', () async {
      await SetupApply.apply(state);
      final workspace = p.join(tempDir.path, 'workspace');
      File(p.join(workspace, 'USER.md')).writeAsStringSync('''
# User Context

## Identity

Existing identity

## Goals

Existing goal

### Personal notes

Freeform footer
''');
      File(p.join(workspace, 'USER.md.draft')).writeAsStringSync('''
# User Context

## Identity

Updated identity

## Goals

Updated goal

## Preferences

Concise answers
''');
      File(p.join(workspace, 'SOUL.md.draft')).writeAsStringSync('New soul\n');

      final applied = await SetupApply.applyDrafts(state, confirmSoulReplace: true);

      expect(applied, contains(p.join(workspace, 'USER.md')));
      expect(applied, contains(p.join(workspace, 'SOUL.md')));
      final user = File(p.join(workspace, 'USER.md')).readAsStringSync();
      expect(user, contains('Updated identity'));
      expect(user, contains('Updated goal'));
      expect(user, isNot(contains('Existing goal')));
      expect(user, contains('Concise answers'));
      expect(user, contains('### Personal notes'));
      expect(user, contains('Freeform footer'));
      expect(File(p.join(workspace, 'SOUL.md')).readAsStringSync(), 'New soul\n');
      expect(File(p.join(workspace, 'USER.md.draft')).existsSync(), isFalse);
      expect(File(p.join(workspace, 'SOUL.md.draft')).existsSync(), isFalse);
    });

    test('applyDrafts applies USER and skips SOUL without explicit confirmation', () async {
      await SetupApply.apply(state);
      final workspace = p.join(tempDir.path, 'workspace');
      File(p.join(workspace, 'USER.md')).writeAsStringSync('# User Context\n\n## Identity\n\nOld\n');
      File(p.join(workspace, 'USER.md.draft')).writeAsStringSync('# User Context\n\n## Identity\n\nNew\n');
      File(p.join(workspace, 'SOUL.md')).writeAsStringSync('Curated soul\n');
      File(p.join(workspace, 'SOUL.md.draft')).writeAsStringSync('New soul\n');

      final applied = await SetupApply.applyDrafts(state, confirmSoulReplace: false);

      expect(applied, [p.join(workspace, 'USER.md')]);
      expect(File(p.join(workspace, 'USER.md')).readAsStringSync(), contains('New'));
      expect(File(p.join(workspace, 'USER.md.draft')).existsSync(), isFalse);
      expect(File(p.join(workspace, 'SOUL.md')).readAsStringSync(), 'Curated soul\n');
      expect(File(p.join(workspace, 'SOUL.md.draft')).existsSync(), isTrue);
    });

    test('applyDrafts preserves trailing freeform content after the last canonical section', () async {
      await SetupApply.apply(state);
      final workspace = p.join(tempDir.path, 'workspace');
      // Preferences is the last canonical ## section present; plain-text footer follows with no heading.
      File(p.join(workspace, 'USER.md')).writeAsStringSync('''
# User Context

## Identity

Existing identity

## Preferences

Existing preference

My personal notes added by the user, no heading
''');
      File(p.join(workspace, 'USER.md.draft')).writeAsStringSync('''
# User Context

## Identity

Updated identity

## Preferences

New preference
''');

      await SetupApply.applyDrafts(state, confirmSoulReplace: false);

      final user = File(p.join(workspace, 'USER.md')).readAsStringSync();
      expect(user, contains('Updated identity'));
      expect(user, contains('New preference'));
      expect(user, isNot(contains('Existing preference')));
      // Trailing user content must survive the update of the last canonical section.
      expect(user, contains('My personal notes added by the user, no heading'));
    });

    test('workflow track writes minimal config and skips server scaffold', () async {
      final workflowState = _state(
        instanceDir: tempDir.path,
        authMethod: 'oauth',
        model: 'claude-sonnet-4-6',
        workflowTrack: true,
      );

      await SetupApply.apply(workflowState);

      final raw = File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync();
      expect(raw, startsWith('# DartClaw — standalone workflow config'));
      expect(raw, contains('dartclaw workflow run --standalone <name>'));
      expect(raw, contains('Drop custom workflow YAMLs in ./.dartclaw/workflows/'));
      // Block style, not a single-line flow map.
      expect(raw, contains('\nagent:\n'));
      expect(raw, contains('\n  provider: claude'));
      expect(raw, isNot(contains('{agent:')));
      final yaml = loadYaml(raw) as Map;
      expect(yaml['data_dir'], '.');
      expect(yaml['agent']['provider'], 'claude');
      expect(yaml['agent']['model'], 'claude-sonnet-4-6');
      expect(yaml['providers']['claude']['executable'], 'claude');
      expect(yaml['providers']['claude']['auth_method'], 'oauth');
      expect(yaml['port'], isNull);
      expect(yaml['host'], isNull);
      expect(yaml['gateway'], isNull);
      expect(
        File(p.join(tempDir.path, '.gitignore')).readAsStringSync(),
        '*\n!.gitignore\n!dartclaw.yaml\n!workflows/\n!workflows/**\nworkflows/built-in/\nworkflows/runs/\n',
      );
      expect(Directory(p.join(tempDir.path, 'workspace')).existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'workspace', 'ONBOARDING.md')).existsSync(), isFalse);
    });

    test('workflow track does not overwrite an existing gitignore', () async {
      File(p.join(tempDir.path, '.gitignore'))
        ..createSync()
        ..writeAsStringSync('custom\n');

      await SetupApply.apply(_state(instanceDir: tempDir.path, workflowTrack: true));

      expect(File(p.join(tempDir.path, '.gitignore')).readAsStringSync(), 'custom\n');
    });

    test('non-workflow track keeps the generic config header (no workflow banner)', () async {
      await SetupApply.apply(_state(instanceDir: tempDir.path));

      final raw = File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync();
      expect(raw, startsWith('# DartClaw configuration'));
      expect(raw, isNot(contains('standalone workflow config')));
    });
  });
}
