import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:yaml_edit/yaml_edit.dart';

import 'setup_state.dart';

/// Applies a resolved [SetupState] to disk:
/// 1. Writes dartclaw.yaml (creates if absent, non-destructive update if present)
/// 2. Scaffolds workspace directories and default behavior files
/// 3. Seeds ONBOARDING.md sentinel
///
/// All mutations happen atomically at the end (atomic config write via tmp+rename).
/// If [state] is null, no writes are made (dry-run).
class SetupApply {
  /// Applies [state] to disk. Idempotent on re-runs.
  ///
  /// Returns a list of files created or updated.
  static Future<List<String>> apply(SetupState state) async {
    final created = <String>[];

    final instanceDir = Directory(state.instanceDir);
    instanceDir.createSync(recursive: true);

    // --- Config file ---
    final configPath = state.configPath;
    final configFile = File(configPath);
    configFile.parent.createSync(recursive: true);
    final configExists = configFile.existsSync();

    final String configContent;
    if (configExists) {
      // Non-destructive update: load current YAML, apply only our keys.
      configContent = configFile.readAsStringSync();
    } else {
      configContent = '# DartClaw configuration\n';
      created.add(configPath);
    }

    final editor = YamlEditor(configContent);
    _set(editor, ['name'], state.instanceName);
    _set(editor, ['port'], state.port);
    _set(editor, ['host'], 'localhost');
    _set(editor, ['data_dir'], state.instanceDir);
    _set(editor, ['agent', 'provider'], state.provider);
    if (state.model != null && state.model!.trim().isNotEmpty) {
      _set(editor, ['agent', 'model'], state.model!.trim());
    } else {
      _remove(editor, ['agent', 'model']);
    }
    _set(editor, ['gateway', 'auth_mode'], state.gatewayAuthMode);

    for (final providerId in const ['claude', 'codex']) {
      final selected = state.providers.contains(providerId);
      if (!selected) {
        _remove(editor, ['providers', providerId]);
        _remove(editor, ['credentials', _credentialNameFor(providerId)]);
        continue;
      }

      _set(editor, ['providers', providerId, 'executable'], _defaultExecutableFor(providerId));

      final authMethod = state.providerAuthMethods[providerId];
      if (authMethod != null && authMethod.isNotEmpty) {
        _set(editor, ['providers', providerId, 'auth_method'], authMethod);
      } else {
        _remove(editor, ['providers', providerId, 'auth_method']);
      }

      final model = state.providerModels[providerId];
      if (model != null && model.isNotEmpty) {
        _set(editor, ['providers', providerId, 'model'], model);
      } else {
        _remove(editor, ['providers', providerId, 'model']);
      }

      if (authMethod == 'env') {
        final envVar = providerId == 'codex' ? 'OPENAI_API_KEY' : 'ANTHROPIC_API_KEY';
        _set(editor, ['credentials', _credentialNameFor(providerId), 'api_key'], '\${$envVar}');
      } else {
        _remove(editor, ['credentials', _credentialNameFor(providerId)]);
      }
    }

    if (state.manageAdvancedSettings) {
      if (state.whatsappEnabled) {
        _set(editor, ['channels', 'whatsapp', 'enabled'], true);
        if (state.gowaExecutable != null && state.gowaExecutable!.isNotEmpty) {
          _set(editor, ['channels', 'whatsapp', 'gowa_executable'], state.gowaExecutable!);
        } else {
          _remove(editor, ['channels', 'whatsapp', 'gowa_executable']);
        }
        if (state.gowaPort != null) {
          _set(editor, ['channels', 'whatsapp', 'gowa_port'], state.gowaPort!);
        } else {
          _remove(editor, ['channels', 'whatsapp', 'gowa_port']);
        }
      } else {
        _remove(editor, ['channels', 'whatsapp']);
      }

      if (state.signalEnabled) {
        _set(editor, ['channels', 'signal', 'enabled'], true);
        if (state.signalPhoneNumber != null && state.signalPhoneNumber!.isNotEmpty) {
          _set(editor, ['channels', 'signal', 'phone_number'], state.signalPhoneNumber!);
        } else {
          _remove(editor, ['channels', 'signal', 'phone_number']);
        }
        if (state.signalExecutable != null && state.signalExecutable!.isNotEmpty) {
          _set(editor, ['channels', 'signal', 'executable'], state.signalExecutable!);
        } else {
          _remove(editor, ['channels', 'signal', 'executable']);
        }
      } else {
        _remove(editor, ['channels', 'signal']);
      }

      if (state.googleChatEnabled) {
        _set(editor, ['channels', 'google_chat', 'enabled'], true);
        if (state.googleChatServiceAccount != null && state.googleChatServiceAccount!.isNotEmpty) {
          _set(editor, ['channels', 'google_chat', 'service_account'], state.googleChatServiceAccount!);
        } else {
          _remove(editor, ['channels', 'google_chat', 'service_account']);
        }
        if (state.googleChatAudienceType != null && state.googleChatAudienceType!.isNotEmpty) {
          _set(editor, ['channels', 'google_chat', 'audience', 'type'], state.googleChatAudienceType!);
        } else {
          _remove(editor, ['channels', 'google_chat', 'audience', 'type']);
        }
        if (state.googleChatAudience != null && state.googleChatAudience!.isNotEmpty) {
          _set(editor, ['channels', 'google_chat', 'audience', 'value'], state.googleChatAudience!);
        } else {
          _remove(editor, ['channels', 'google_chat', 'audience', 'value']);
        }
      } else {
        _remove(editor, ['channels', 'google_chat']);
      }

      if (state.containerEnabled) {
        _set(editor, ['container', 'enabled'], true);
        if (state.containerImage != null && state.containerImage!.isNotEmpty) {
          _set(editor, ['container', 'image'], state.containerImage!);
        } else {
          _remove(editor, ['container', 'image']);
        }
      } else {
        _remove(editor, ['container']);
      }

      if (state.contentGuardEnabled != null) {
        _set(editor, ['guards', 'content', 'enabled'], state.contentGuardEnabled!);
      }
      if (state.inputSanitizerEnabled != null) {
        _set(editor, ['guards', 'input_sanitizer', 'enabled'], state.inputSanitizerEnabled!);
      }
    }

    // Atomic write: tmp file + rename
    final tmpPath = '$configPath.tmp';
    final tmpFile = File(tmpPath);
    tmpFile.writeAsStringSync(editor.toString());
    tmpFile.renameSync(configPath);

    if (configExists) {
      created.add('$configPath (updated)');
    }

    // --- Workspace scaffold ---
    final workspaceDir = p.join(state.instanceDir, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);
    Directory(p.join(state.instanceDir, 'sessions')).createSync(recursive: true);
    Directory(p.join(state.instanceDir, 'logs')).createSync(recursive: true);

    for (final entry in {
      'SOUL.md': WorkspaceService.defaultSoulMd,
      'AGENTS.md': WorkspaceService.defaultAgentsMd,
      'USER.md': WorkspaceService.defaultUserMd,
      'TOOLS.md': WorkspaceService.defaultToolsMd,
    }.entries) {
      final file = File(p.join(workspaceDir, entry.key));
      if (!file.existsSync()) {
        file.writeAsStringSync(entry.value);
        created.add(file.path);
      }
    }

    // --- ONBOARDING.md sentinel ---
    final onboardingPath = p.join(workspaceDir, 'ONBOARDING.md');
    final onboardingFile = File(onboardingPath);
    if (!onboardingFile.existsSync()) {
      onboardingFile.writeAsStringSync(_buildOnboarding(state));
      created.add(onboardingPath);
    }

    return created;
  }

  static void _set(YamlEditor editor, List<String> path, Object value) {
    try {
      editor.update(path, value);
    } on ArgumentError {
      // Create intermediate maps as needed
      final parsed = editor.parseAt([]);
      if (parsed.value == null) {
        editor.update([], {});
      }
      for (var i = 0; i < path.length - 1; i++) {
        final subPath = path.sublist(0, i + 1);
        try {
          editor.parseAt(subPath);
        } on ArgumentError {
          editor.update(subPath, {});
        }
      }
      editor.update(path, value);
    }
  }

  static void _remove(YamlEditor editor, List<String> path) {
    try {
      editor.remove(path);
    } on ArgumentError {
      // Already absent.
    }
  }

  static String _credentialNameFor(String providerId) {
    return switch (providerId) {
      'codex' => 'openai',
      _ => 'anthropic',
    };
  }

  static String _defaultExecutableFor(String providerId) {
    return switch (providerId) {
      'codex' => 'codex',
      _ => 'claude',
    };
  }

  static String _buildOnboarding(SetupState state) {
    final buffer = StringBuffer();
    buffer.writeln('# DartClaw Onboarding');
    buffer.writeln('<!--');
    buffer.writeln('  This file is a sentinel for DartClaw\'s conversational bootstrapping (0.17+).');
    buffer.writeln('  When you start a conversation, the agent will use this file to introduce');
    buffer.writeln('  itself and collaboratively set up your behavior files (SOUL.md, USER.md).');
    buffer.writeln('  This file will be deleted when onboarding completes.');
    buffer.writeln('  Do not edit manually — to re-trigger, run: dartclaw init --personalize');
    buffer.writeln('-->');
    buffer.writeln();
    buffer.writeln('## Setup Context');
    buffer.writeln('- Instance name: ${state.instanceName}');
    buffer.writeln('- Provider: ${state.provider}');
    buffer.writeln('- Port: ${state.port}');
    buffer.writeln();
    buffer.writeln('## Instructions for the Agent');
    buffer.writeln();
    buffer.writeln('When you see this file in your workspace, you are running in a newly');
    buffer.writeln('set-up DartClaw instance. On the user\'s first message:');
    buffer.writeln();
    buffer.writeln('1. Greet the user warmly and acknowledge this is a fresh setup.');
    buffer.writeln('2. If the user has a task, address it first, then offer to do onboarding.');
    buffer.writeln('3. Ask about the user\'s name, how they\'d like to be addressed, timezone,');
    buffer.writeln('   and what they mainly use this assistant for.');
    buffer.writeln('4. Collaboratively decide on a name and personality for yourself. Update SOUL.md.');
    buffer.writeln('5. Record user context in USER.md (identity, goals, preferences).');
    buffer.writeln('6. When onboarding is complete, delete this file or call onboarding_complete.');
    buffer.writeln('7. If the user says "skip" or "later", acknowledge and explain how to re-trigger');
    buffer.writeln('   (run: dartclaw init --personalize).');
    return buffer.toString();
  }
}
