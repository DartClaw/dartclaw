import 'dart:io';

import 'package:dartclaw_cli/src/commands/init/setup_apply.dart';
import 'package:dartclaw_cli/src/commands/init/setup_state.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ConfigMeta;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
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
      expect(yaml['governance']['turn_limits']['stall_timeout'], '300s');
      expect(yaml['governance']['turn_limits']['stall_action'], 'cancel');
      expect(yaml['governance']['turn_limits']['turn_timeout'], '1800s');
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
      );
      await SetupApply.apply(guarded);

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['guards']['content']['enabled'], isFalse);
    });

    test('rerun removes deselected providers, channels, and env credentials, and disables container', () async {
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
      );
      await SetupApply.apply(rerun);

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['providers']['claude'], isNotNull);
      expect(yaml['providers']['codex'], isNull);
      expect(yaml['credentials']['openai'], isNull);
      expect(yaml['channels']['whatsapp'], isNull);
      // Declining isolation is written, not removed: an absent `container:`
      // section means "isolate if this host can", so removing it would answer
      // the opposite of what the operator chose on any host with a runtime.
      expect(yaml['container']['enabled'], isFalse);
      expect(yaml['container']['image'], isNull);
      expect(yaml['guards']['content']['enabled'], isTrue);
    });

    // The quick track never puts the container question, so its silence must
    // stay silence: an absent section resolves the posture from the host, and
    // writing either literal would answer for the operator.
    test('a track that never asks writes no container section at all', () async {
      await SetupApply.apply(
        SetupState(
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
        ),
      );

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['container'], isNull);
    });

    test('a first run that declines isolation writes it rather than leaving it to detection', () async {
      await SetupApply.apply(
        SetupState(
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
          containerEnabled: false,
        ),
      );

      final yaml = loadYaml(File(p.join(tempDir.path, 'dartclaw.yaml')).readAsStringSync()) as Map;
      expect(yaml['container']['enabled'], isFalse);
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

    for (final existingFiles in const [
      ['USER.md'],
      ['SOUL.md'],
      ['USER.md', 'SOUL.md'],
    ]) {
      test('${existingFiles.join(' and ')} force draft onboarding', () async {
        final workspace = Directory(p.join(tempDir.path, 'workspace'))..createSync(recursive: true);
        for (final name in existingFiles) {
          File(p.join(workspace.path, name)).writeAsStringSync('curated $name');
        }

        await SetupApply.apply(state);

        final onboarding = File(p.join(workspace.path, 'ONBOARDING.md')).readAsStringSync();
        expect(onboarding, contains('Rerun: true'));
        expect(onboarding, contains('USER.md.draft'));
        expect(onboarding, contains('SOUL.md.draft'));
        for (final name in existingFiles) {
          expect(File(p.join(workspace.path, name)).readAsStringSync(), 'curated $name');
        }
      });
    }

    test('rerun upgrades generated direct-mode behavior instructions without replacing curated content', () async {
      await SetupApply.apply(state);
      final workspace = p.join(tempDir.path, 'workspace');
      final userFile = File(p.join(workspace, 'USER.md'))..writeAsStringSync('curated user');
      final onboardingFile = File(p.join(workspace, 'ONBOARDING.md'));
      const customOnboarding = '''
## Custom note
- Rerun: false
- Draft mode: first-run files may be updated directly
6. On first run, write USER.md and SOUL.md directly. On reruns, read existing USER.md
   and SOUL.md first, then write USER.md.draft and SOUL.md.draft for review.
6. If Draft mode is enabled, read USER.md and SOUL.md first, then write USER.md.draft
   and SOUL.md.draft for review. Otherwise, write USER.md and SOUL.md directly.
6. Write USER.md and SOUL.md directly.
Keep me.
''';
      onboardingFile.writeAsStringSync('${onboardingFile.readAsStringSync()}$customOnboarding');
      final soulFile = File(p.join(workspace, 'SOUL.md'))
        ..writeAsStringSync('''
Curated preface.
During first-run onboarding you may write this file directly; during
reruns, propose changes in SOUL.md.draft and wait for the user to apply them.
Curated suffix.
''');

      await SetupApply.apply(state);

      final onboarding = onboardingFile.readAsStringSync();
      final customStart = onboarding.indexOf('## Custom note');
      final generatedOnboarding = onboarding.substring(0, customStart);
      expect(generatedOnboarding, contains('Rerun: true'));
      expect(generatedOnboarding, isNot(contains('first-run files may be updated directly')));
      expect(generatedOnboarding, isNot(contains('Write USER.md and SOUL.md directly')));
      expect(onboarding.substring(customStart), customOnboarding);
      expect(userFile.readAsStringSync(), 'curated user');
      expect(soulFile.readAsStringSync(), contains('Curated preface.'));
      expect(soulFile.readAsStringSync(), contains('Curated suffix.'));
      expect(soulFile.readAsStringSync(), contains('follow its Draft mode'));
      expect(soulFile.readAsStringSync(), isNot(contains('you may write this file directly')));
    });

    test('scaffolded SOUL does not authorize direct onboarding writes', () async {
      await SetupApply.apply(state);

      final soul = File(p.join(tempDir.path, 'workspace', 'SOUL.md')).readAsStringSync();
      expect(soul, isNot(contains('you may write this file directly')));
      expect(soul, contains('SOUL.md.draft'));
      expect(soul, contains('follow its Draft mode'));
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
      expect(raw.split('\n').first, '# yaml-language-server: \$schema=${ConfigMeta.jsonSchemaUrl(dartclawVersion)}');
      expect(raw.split('\n')[1], startsWith('# DartClaw — standalone workflow config'));
      expect(raw, contains('dartclaw workflow run --standalone <name>'));
      expect(raw, contains('Drop custom workflow YAMLs in ./.dartclaw/workflows/custom/'));
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
        '*\n!.gitignore\n!dartclaw.yaml\n!workflows/\n!workflows/**\nworkflows/**/.DS_Store\nworkflows/built-in/\nworkflows/runs/\n',
      );
      expect(Directory(p.join(tempDir.path, 'workspace')).existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'workspace', 'ONBOARDING.md')).existsSync(), isFalse);
    });

    for (final workflowTrack in [false, true]) {
      test('existing config retains its user header without a modeline (workflow: $workflowTrack)', () async {
        final file = File(p.join(tempDir.path, 'dartclaw.yaml'));
        file.writeAsStringSync('# My configuration\ndata_dir: .\nagent:\n  provider: claude\n');

        await SetupApply.apply(_state(instanceDir: tempDir.path, workflowTrack: workflowTrack));

        final raw = file.readAsStringSync();
        expect(raw.split('\n').first, '# My configuration');
        expect(raw, isNot(contains('yaml-language-server')));
      });
    }

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
      expect(raw.split('\n').first, '# yaml-language-server: \$schema=${ConfigMeta.jsonSchemaUrl(dartclawVersion)}');
      expect(raw.split('\n')[1], '# DartClaw configuration');
      expect(raw, isNot(contains('standalone workflow config')));
    });
  });
}
