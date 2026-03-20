import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SessionKey;
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

  final String workspaceDir;
  final String? projectDir;
  final int? maxMemoryBytes;

  /// Custom compact instructions to include in system prompts for long-running sessions.
  ///
  /// When null, [defaultCompactInstructions] is used.
  final String? compactInstructions;

  BehaviorFileService({required this.workspaceDir, this.projectDir, this.maxMemoryBytes, this.compactInstructions});

  /// Composes the full system prompt.
  ///
  /// When [sessionId] is provided, compact instructions are included based
  /// on the session scope. Task sessions skip compact instructions (short-lived).
  /// When [sessionId] is null, compact instructions are included by default.
  Future<String> composeSystemPrompt({String? sessionId}) async {
    final parts = await _loadCoreParts();

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

    // Compact instructions — skip for task sessions (short-lived, compaction never triggers)
    if (_shouldIncludeCompactInstructions(sessionId)) {
      final instructions = compactInstructions ?? defaultCompactInstructions;
      parts.add('# Compact instructions\n$instructions');
    }

    return parts.join('\n\n');
  }

  /// Whether compact instructions should be included for this session scope.
  ///
  /// Includes for: web, dm, group, cron (multi-turn, may hit compaction).
  /// Skips for: task (single-turn execution, compaction never triggers).
  /// Defaults to true when sessionId is null or unparseable (conservative).
  static bool _shouldIncludeCompactInstructions(String? sessionId) {
    if (sessionId == null) return true;
    try {
      final key = SessionKey.parse(sessionId);
      return key.scope != 'task';
    } catch (_) {
      return true;
    }
  }

  /// Composes static prompt content for append-mode harnesses.
  /// Includes SOUL, USER, TOOLS, AGENTS (no MEMORY -- agent uses MCP tools).
  Future<String> composeStaticPrompt() async {
    final parts = await _loadCoreParts();

    // AGENTS.md
    final agentsMd = await composeAppendPrompt();
    if (agentsMd.isNotEmpty) {
      parts.add(agentsMd);
    }

    // Memory hint (agent uses MCP tools for dynamic memory access)
    parts.add('## Memory\nUse the memory_read tool to check for relevant context before responding.');

    return parts.join('\n\n');
  }

  /// Loads the shared core prompt parts: SOUL, USER, TOOLS, errors, learnings.
  Future<List<String>> _loadCoreParts() async {
    final parts = <String>[];
    final projDir = projectDir;

    // SOUL.md — workspace then project
    final globalSoul = await _readFile(p.join(workspaceDir, 'SOUL.md'));
    if (globalSoul != null) parts.add(globalSoul);
    final projSoul = projDir != null ? await _readFile(p.join(projDir, 'SOUL.md')) : null;
    if (projSoul != null) parts.add(projSoul);
    if (globalSoul == null && projSoul == null) parts.add(defaultPrompt);

    // USER.md — workspace only (agent-updatable user context)
    await _addSection(parts, 'USER.md', '## User Context');
    // TOOLS.md — workspace only (human-maintained environment notes)
    await _addSection(parts, 'TOOLS.md', '## Environment Notes');
    // errors.md — auto-populated on failures
    await _addSection(parts, 'errors.md', '## Recent Errors');
    // learnings.md — agent-written via memory_save category='learning'
    await _addSection(parts, 'learnings.md', '## Learnings');

    return parts;
  }

  /// Reads a workspace file and adds it as a headed section if non-empty.
  Future<void> _addSection(List<String> parts, String filename, String header) async {
    final content = await _readFile(p.join(workspaceDir, filename));
    if (content != null && content.trim().isNotEmpty) {
      parts.add('$header\n$content');
    }
  }

  /// Loads AGENTS.md from workspace and returns its content for append to system prompt.
  /// Returns empty string if file is missing or unreadable (never throws).
  Future<String> composeAppendPrompt() async {
    final content = await _readFile(p.join(workspaceDir, 'AGENTS.md'));
    return content ?? '';
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
