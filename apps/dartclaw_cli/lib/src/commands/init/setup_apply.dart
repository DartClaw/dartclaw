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
  static const canonicalUserSections = [
    'Identity',
    'Goals',
    'Current Challenges',
    'Preferences',
    'Proactivity Level',
    'Not Relevant',
  ];

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
    if (state.workflowTrack) {
      _remove(editor, ['name']);
      _remove(editor, ['port']);
      _remove(editor, ['host']);
      _remove(editor, ['gateway']);
    } else {
      _set(editor, ['name'], state.instanceName);
      _set(editor, ['port'], state.port);
      _set(editor, ['host'], 'localhost');
      _set(editor, ['gateway', 'auth_mode'], state.gatewayAuthMode);
    }
    _set(editor, ['data_dir'], state.workflowTrack ? '.' : state.instanceDir);
    _set(editor, ['agent', 'provider'], state.provider);
    if (state.model != null && state.model!.trim().isNotEmpty) {
      _set(editor, ['agent', 'model'], state.model!.trim());
    } else {
      _remove(editor, ['agent', 'model']);
    }
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
        final envVar = providerId == 'codex' ? 'CODEX_API_KEY' : 'ANTHROPIC_API_KEY';
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

    if (state.workflowTrack) {
      return created;
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
      p.join('wiki', 'README.md'): WorkspaceService.defaultWikiReadmeMd,
    }.entries) {
      final file = File(p.join(workspaceDir, entry.key));
      if (!file.existsSync()) {
        file.parent.createSync(recursive: true);
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

  /// Re-seeds ONBOARDING.md for a personalization rerun without touching curated behavior files.
  static Future<List<String>> personalize(SetupState state) async {
    final workspaceDir = p.join(state.instanceDir, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);

    final onboardingPath = p.join(workspaceDir, 'ONBOARDING.md');
    File(onboardingPath).writeAsStringSync(_buildOnboarding(state, personalize: true));
    return [onboardingPath];
  }

  /// Applies accepted USER.md.draft and SOUL.md.draft files.
  static Future<List<String>> applyDrafts(SetupState state, {required bool confirmSoulReplace}) async {
    final workspaceDir = p.join(state.instanceDir, 'workspace');
    final applied = <String>[];

    final soulPath = p.join(workspaceDir, 'SOUL.md');
    final soulDraftPath = '$soulPath.draft';
    final soulDraft = File(soulDraftPath);

    final userPath = p.join(workspaceDir, 'USER.md');
    final userDraftPath = '$userPath.draft';
    final userDraft = File(userDraftPath);
    if (userDraft.existsSync()) {
      final userFile = File(userPath);
      final existing = userFile.existsSync() ? userFile.readAsStringSync() : WorkspaceService.defaultUserMd;
      final draft = userDraft.readAsStringSync();
      userFile.writeAsStringSync(_mergeUserSections(existing, draft));
      userDraft.deleteSync();
      applied.add(userPath);
    }

    if (soulDraft.existsSync() && confirmSoulReplace) {
      File(soulPath).writeAsStringSync(soulDraft.readAsStringSync());
      soulDraft.deleteSync();
      applied.add(soulPath);
    }

    return applied;
  }

  static String _mergeUserSections(String existing, String draft) {
    var merged = existing;
    for (final section in canonicalUserSections) {
      final draftSection = _extractSection(draft, section);
      if (draftSection == null || draftSection.trim().isEmpty) continue;
      merged = _replaceOrAppendSection(merged, section, draftSection.trimRight());
    }
    return merged.endsWith('\n') ? merged : '$merged\n';
  }

  static String? _extractSection(String content, String section) {
    final ranges = _sectionRanges(content);
    final range = ranges[section];
    if (range == null) return null;
    return content.substring(range.start, range.end).trim();
  }

  static String _replaceOrAppendSection(String content, String section, String body) {
    final replacement = '## $section\n\n$body\n';
    final ranges = _sectionRanges(content);
    final range = ranges[section];
    if (range != null) {
      // Preserve user-added content that trails the section body but has no heading to act as a boundary.
      // Sub-heading boundaries are already handled: _sectionRanges stops at the next heading, so content
      // from range.end onwards is automatically preserved by replaceRange. The gap only occurs when the
      // section is the last ## heading (range.end == content.length) and trailing content is plain text.
      final userTail = _trailingUserContent(content, range);
      return content.replaceRange(range.headingStart, range.end, '$replacement$userTail');
    }
    final separator = content.trimRight().isEmpty ? '' : '\n\n';
    return '${content.trimRight()}$separator$replacement';
  }

  // Returns any trailing plain-text content within a section range that should be preserved when
  // replacing the section body. Only applies to the last ## section (range.end == content.length),
  // since for earlier sections the next heading already bounds the replacement range. Trailing content
  // is detected as non-blank paragraphs appearing after the section's first body paragraph.
  static String _trailingUserContent(String content, ({int headingStart, int start, int end}) range) {
    if (range.end < content.length) return '';
    final sectionBody = content.substring(range.start, range.end);
    final trimmed = sectionBody.trimLeft();
    if (trimmed.isEmpty) return '';
    // Find the end of the first paragraph (first \n\n after actual content begins).
    final contentStart = sectionBody.length - trimmed.length;
    final firstParaBreak = sectionBody.indexOf('\n\n', contentStart);
    if (firstParaBreak < 0) return '';
    final tail = sectionBody.substring(firstParaBreak).trimLeft();
    // Only preserve if tail is non-empty plain text (not another heading — those are handled separately).
    if (tail.isEmpty || RegExp(r'^#{1,6}\s').hasMatch(tail)) return '';
    return '\n$tail';
  }

  static Map<String, ({int headingStart, int start, int end})> _sectionRanges(String content) {
    final headings = RegExp(r'^(#{1,6})\s+(.+?)\s*$', multiLine: true).allMatches(content).toList(growable: false);
    final ranges = <String, ({int headingStart, int start, int end})>{};
    for (var i = 0; i < headings.length; i++) {
      final match = headings[i];
      if (match.group(1) != '##') continue;
      final title = match.group(2);
      if (title == null) continue;
      ranges[title] = (
        headingStart: match.start,
        start: match.end,
        end: i + 1 < headings.length ? headings[i + 1].start : content.length,
      );
    }
    return ranges;
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

  static String _buildOnboarding(SetupState state, {bool personalize = false}) {
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
    if (personalize) {
      buffer.writeln('- Rerun: true');
      buffer.writeln('- Draft mode: write USER.md.draft and SOUL.md.draft instead of overwriting curated files');
    } else {
      buffer.writeln('- Rerun: false');
      buffer.writeln('- Draft mode: first-run files may be updated directly');
    }
    buffer.writeln();
    buffer.writeln('## Instructions for the Agent');
    buffer.writeln();
    buffer.writeln('When you see this file in your workspace, you are running in a newly');
    buffer.writeln('set-up DartClaw instance. On the user\'s first message:');
    buffer.writeln();
    buffer.writeln('1. Greet the user warmly and acknowledge this is a fresh setup.');
    buffer.writeln('2. If the user has a task, address it first, then offer to do onboarding.');
    buffer.writeln('3. Ask only for information the user is willing to provide. Do not invent missing personal data.');
    buffer.writeln('4. Populate USER.md using exactly these sections:');
    buffer.writeln('   Identity, Goals, Current Challenges, Preferences, Proactivity Level, Not Relevant.');
    buffer.writeln('5. Collaboratively decide on durable behavior and proactivity guidance for SOUL.md.');
    buffer.writeln('6. On first run, write USER.md and SOUL.md directly. On reruns, read existing USER.md');
    buffer.writeln('   and SOUL.md first, then write USER.md.draft and SOUL.md.draft for review.');
    buffer.writeln('7. USER.md.draft should only update answered sections; leave unsupplied sections as');
    buffer.writeln('   placeholders or preserve prior content.');
    buffer.writeln('8. If the user says "skip" or "later", acknowledge the deferral and explain the rerun path:');
    buffer.writeln('   dartclaw init --personalize.');
    buffer.writeln('9. Drafts can be applied with dartclaw init --apply-drafts.');
    buffer.writeln('10. When onboarding is complete, call onboarding_complete.');
    return buffer.toString();
  }
}
