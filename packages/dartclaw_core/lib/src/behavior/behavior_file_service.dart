import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class BehaviorFileService {
  static final _log = Logger('BehaviorFileService');
  static const defaultPrompt = 'You are a helpful, capable AI assistant.';

  final String workspaceDir;
  final String? projectDir;
  final int? maxMemoryBytes;

  BehaviorFileService({required this.workspaceDir, this.projectDir, this.maxMemoryBytes});

  Future<String> composeSystemPrompt() async {
    final parts = <String>[];
    final projDir = projectDir;

    // 1. SOUL.md — workspace then project
    final globalSoul = await _readFile(p.join(workspaceDir, 'SOUL.md'));
    if (globalSoul != null) parts.add(globalSoul);
    final projSoul = projDir != null ? await _readFile(p.join(projDir, 'SOUL.md')) : null;
    if (projSoul != null) parts.add(projSoul);

    // 2. If no SOUL.md found anywhere, use hardcoded default
    if (globalSoul == null && projSoul == null) parts.add(defaultPrompt);

    // 3. USER.md — workspace only (agent-updatable user context)
    final userMd = await _readFile(p.join(workspaceDir, 'USER.md'));
    if (userMd != null && userMd.trim().isNotEmpty) {
      parts.add('## User Context\n$userMd');
    }

    // 4. TOOLS.md — workspace only (human-maintained environment notes)
    final toolsMd = await _readFile(p.join(workspaceDir, 'TOOLS.md'));
    if (toolsMd != null && toolsMd.trim().isNotEmpty) {
      parts.add('## Environment Notes\n$toolsMd');
    }

    // 5. MEMORY.md — workspace only
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

    return parts.join('\n\n');
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
    try {
      return await File(path).readAsString();
    } on FileSystemException catch (e) {
      _log.warning('Skipping $path: ${e.message}');
      return null;
    } on FormatException catch (e) {
      _log.warning('Skipping $path (invalid encoding): ${e.message}');
      return null;
    }
  }
}
