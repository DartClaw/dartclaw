import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show IdentifierPreservationMode;
import 'package:dartclaw_core/dartclaw_core.dart' show PromptScope;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Reads and manages the agent behavior prompt file (BEHAVIOR.md).
class BehaviorFileService {
  static final _log = Logger('BehaviorFileService');
  static const defaultPrompt = 'You are a helpful, capable AI assistant.';

  /// Default compact instructions used when no custom value is configured.
  static const defaultCompactInstructions =
      'When compacting context, preserve:\n'
      '1. All user instructions, preferences, and decisions\n'
      '2. Current task state, goals, and acceptance criteria\n'
      '3. Key code patterns, file paths, and architectural decisions discussed\n'
      '4. Error messages and their resolutions\n'
      '5. Tool output summaries (not raw output)\n'
      'Prioritize preserving WHY decisions were made over WHAT was done.';

  /// Default identifier preservation text appended to compact instructions when
  /// [identifierPreservation] is `'strict'`.
  static const defaultIdentifierPreservationText =
      'Preserve all opaque identifiers verbatim: UUIDs, session keys, task IDs, '
      'file paths, hostnames, and URLs.';

  final String workspaceDir;
  final String? projectDir;
  final int? maxMemoryBytes;
  final int onboardingExpiryDays;

  /// Custom compact instructions to include in system prompts for long-running sessions.
  ///
  /// When null, [defaultCompactInstructions] is used.
  final String? compactInstructions;

  /// Controls identifier preservation text appended to compact instructions.
  final IdentifierPreservationMode identifierPreservation;

  /// Custom identifier preservation text used with [IdentifierPreservationMode.custom].
  final String? identifierInstructions;

  /// Tracks whether the project SOUL.md deprecation warning has been logged.
  bool _projSoulDeprecationWarned = false;

  BehaviorFileService({
    required this.workspaceDir,
    this.projectDir,
    this.maxMemoryBytes,
    this.onboardingExpiryDays = 14,
    this.compactInstructions,
    this.identifierPreservation = IdentifierPreservationMode.strict,
    this.identifierInstructions,
  });

  /// Composes the full system prompt for the given [scope].
  ///
  /// Files included per scope:
  /// - [PromptScope.interactive]: SOUL + USER + TOOLS + errors + learnings + MEMORY + compact instructions
  /// - [PromptScope.webInteractive]: interactive + fresh ONBOARDING.md
  /// - [PromptScope.task]: SOUL (workspace) + TOOLS
  /// - [PromptScope.restricted]: TOOLS only
  /// - [PromptScope.evaluator]: default prompt only
  ///
  /// Omitting [scope] is identical to passing [PromptScope.interactive] (backward compat).
  Future<String> composeSystemPrompt({PromptScope scope = PromptScope.interactive}) async {
    // Evaluator gets minimal identity — no workspace behavior files.
    if (scope == PromptScope.evaluator) return defaultPrompt;

    final parts = <String>[];

    // SOUL.md — workspace only (project SOUL.md is deprecated; harness binary reads CLAUDE.md/AGENTS.md natively)
    if (scope != PromptScope.restricted) {
      _checkProjectSoulDeprecation();
      final globalSoul = await _readFile(p.join(workspaceDir, 'SOUL.md'));
      if (globalSoul != null) {
        parts.add(globalSoul);
      } else {
        parts.add(defaultPrompt);
      }
    }

    if (scope == PromptScope.restricted) {
      // Restricted: TOOLS.md only. Apply default prompt if nothing was loaded.
      await _addSection(parts, 'TOOLS.md', '## Environment Notes');
      if (parts.isEmpty) parts.add(defaultPrompt);
      return parts.join('\n\n');
    }

    // interactive and task scopes: SOUL → USER (interactive only) → TOOLS → ...
    if (_includesInteractiveContext(scope)) {
      // USER.md — workspace only (agent-updatable user context)
      await _addSection(parts, 'USER.md', '## User Context');
    }

    // TOOLS.md — workspace only (interactive and task scopes)
    await _addSection(parts, 'TOOLS.md', '## Environment Notes');

    if (_includesInteractiveContext(scope)) {
      // errors.md — auto-populated on failures
      await _addSection(parts, 'errors.md', '## Recent Errors');
      // learnings.md — agent-written via memory_save category='learning'
      await _addSection(parts, 'learnings.md', '## Learnings');

      // MEMORY.md — workspace only
      var memory = await _readFile(p.join(workspaceDir, 'MEMORY.md'));
      if (memory != null) {
        final maxBytes = maxMemoryBytes;
        if (maxBytes != null) {
          final originalLength = utf8.encode(memory).length;
          if (originalLength > maxBytes) {
            memory = _truncateMemory(memory, maxBytes);
            _log.warning('MEMORY.md truncated from $originalLength to ~$maxBytes bytes');
          }
        }
        parts.add(memory);
      }

      // Compact instructions — interactive sessions only (multi-turn, compaction may trigger)
      final instructions = compactInstructions ?? defaultCompactInstructions;
      final identifierText = switch (identifierPreservation) {
        IdentifierPreservationMode.strict => defaultIdentifierPreservationText,
        IdentifierPreservationMode.custom => identifierInstructions,
        IdentifierPreservationMode.off => null,
      };
      final fullInstructions = identifierText != null ? '$instructions\n$identifierText' : instructions;
      parts.add('# Compact instructions\n$fullInstructions');

      await _addOnboardingSection(parts, scope: scope);
    }

    return parts.join('\n\n');
  }

  /// Composes static prompt content for append-mode harnesses.
  ///
  /// Scope controls which workspace files are included at spawn time:
  /// - [PromptScope.interactive]: SOUL + USER + TOOLS + errors + learnings + AGENTS + memory hint
  /// - [PromptScope.webInteractive]: interactive + fresh ONBOARDING.md
  /// - [PromptScope.task]: SOUL + TOOLS + AGENTS + memory hint
  /// - [PromptScope.restricted]: TOOLS + memory hint
  /// - [PromptScope.evaluator]: default prompt + memory hint
  Future<String> composeStaticPrompt({PromptScope scope = PromptScope.interactive}) async {
    final parts = <String>[];

    if (scope == PromptScope.evaluator) {
      parts.add(defaultPrompt);
    } else if (scope == PromptScope.restricted) {
      await _addSection(parts, 'TOOLS.md', '## Environment Notes');
      if (parts.isEmpty) {
        parts.add(defaultPrompt);
      }
    } else {
      _checkProjectSoulDeprecation();
      final globalSoul = await _readFile(p.join(workspaceDir, 'SOUL.md'));
      if (globalSoul != null) {
        parts.add(globalSoul);
      } else {
        parts.add(defaultPrompt);
      }

      if (_includesInteractiveContext(scope)) {
        // USER.md — workspace only (agent-updatable user context)
        await _addSection(parts, 'USER.md', '## User Context');
      }

      // TOOLS.md — workspace only (human-maintained environment notes)
      await _addSection(parts, 'TOOLS.md', '## Environment Notes');

      if (_includesInteractiveContext(scope)) {
        // errors.md — auto-populated on failures
        await _addSection(parts, 'errors.md', '## Recent Errors');
        // learnings.md — agent-written via memory_save category='learning'
        await _addSection(parts, 'learnings.md', '## Learnings');
      }
    }

    await _addOnboardingSection(parts, scope: scope);

    // AGENTS.md
    final agentsMd = await composeAppendPrompt(scope: scope);
    if (agentsMd.isNotEmpty) {
      parts.add(agentsMd);
    }

    parts.add(
      '## Memory\n'
      'Use the memory_read tool for relevant durable context. For questions about entities, dates, timelines, or '
      'changing facts, query the temporal knowledge graph with kg_query or kg_timeline before answering.',
    );

    return parts.join('\n\n');
  }

  /// Whether a fresh onboarding sentinel is available for web prompt injection.
  bool hasFreshOnboardingSentinel({bool logStale = false}) {
    final onboardingFile = File(p.join(workspaceDir, 'ONBOARDING.md'));
    if (!onboardingFile.existsSync()) return false;
    final age = DateTime.now().difference(onboardingFile.statSync().modified);
    final isFresh = age.inDays < onboardingExpiryDays;
    if (!isFresh && logStale) {
      _logStaleOnboarding(age);
    }
    return isFresh;
  }

  /// Returns AGENTS.md content for appending to the system prompt.
  ///
  /// Returns empty string for [PromptScope.restricted] and [PromptScope.evaluator]
  /// (no workspace identity in sandboxed/independent contexts).
  /// Returns empty string if AGENTS.md is missing or unreadable (never throws).
  Future<String> composeAppendPrompt({PromptScope scope = PromptScope.interactive}) async {
    if (scope == PromptScope.restricted || scope == PromptScope.evaluator) return '';
    final content = await _readFile(p.join(workspaceDir, 'AGENTS.md'));
    return content ?? '';
  }

  /// Reads a workspace file and adds it as a headed section if non-empty.
  Future<void> _addSection(List<String> parts, String filename, String header) async {
    final content = await _readFile(p.join(workspaceDir, filename));
    if (content != null && content.trim().isNotEmpty) {
      parts.add('$header\n$content');
    }
  }

  bool _includesInteractiveContext(PromptScope scope) {
    return scope == PromptScope.interactive || scope == PromptScope.webInteractive;
  }

  Future<void> _addOnboardingSection(List<String> parts, {PromptScope scope = PromptScope.webInteractive}) async {
    if (scope != PromptScope.webInteractive) return;
    final onboardingFile = File(p.join(workspaceDir, 'ONBOARDING.md'));
    if (!onboardingFile.existsSync()) return;

    final stat = onboardingFile.statSync();
    final age = DateTime.now().difference(stat.modified);
    if (age.inDays >= onboardingExpiryDays) {
      _logStaleOnboarding(age);
      return;
    }

    final content = await _readFile(onboardingFile.path);
    if (content != null && content.trim().isNotEmpty) {
      parts.add('## Onboarding\n$content');
    }
  }

  void _logStaleOnboarding(Duration age) {
    _log.warning(
      'Skipping stale ONBOARDING.md (${age.inDays} days old). '
      'Run dartclaw init --personalize to restart onboarding.',
    );
  }

  /// Logs a one-shot deprecation warning if project SOUL.md exists.
  void _checkProjectSoulDeprecation() {
    if (_projSoulDeprecationWarned) return;
    final projDir = projectDir;
    if (projDir == null) return;
    final projSoulPath = p.join(projDir, 'SOUL.md');
    if (File(projSoulPath).existsSync()) {
      _projSoulDeprecationWarned = true;
      _log.warning(
        'Project SOUL.md found at $projSoulPath — this file is no longer read. '
        'Use CLAUDE.md (Claude Code) or AGENTS.md (other agents) instead.',
      );
    }
  }

  /// Truncates memory content from the start (oldest entries).
  /// Finds the first `\n## ` boundary after the cut point.
  /// Falls back to raw byte offset if no boundary exists.
  static String _truncateMemory(String content, int maxBytes) {
    final bytes = utf8.encode(content);
    if (bytes.length <= maxBytes) return content;

    // Start from byte offset that keeps the last ~maxBytes of content
    var startByte = bytes.length - maxBytes;
    // Skip forward past any UTF-8 continuation bytes (10xxxxxx) to a valid char boundary
    while (startByte < bytes.length && (bytes[startByte] & 0xC0) == 0x80) {
      startByte++;
    }

    final truncated = utf8.decode(bytes.sublist(startByte));

    // Look for first section boundary in the truncated content
    final boundaryIdx = truncated.indexOf('\n## ');
    if (boundaryIdx >= 0) {
      return truncated.substring(boundaryIdx + 1); // +1 to skip the leading \n
    }
    return truncated;
  }

  Future<String?> _readFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }

    try {
      return await file.readAsString();
    } on FileSystemException catch (e) {
      _log.warning('Skipping $path: ${e.message}');
      return null;
    } on FormatException catch (e) {
      _log.warning('Skipping $path (invalid encoding): ${e.message}');
      return null;
    }
  }
}
