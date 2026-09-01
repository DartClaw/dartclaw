import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' as core;
import 'package:path/path.dart' as p;

import 'knowledge_inbox_service.dart';

/// Read-only view over knowledge inbox folders.
final class KnowledgeInboxReadService {
  static const folders = ['inbox', 'processed', 'quarantine', 'skipped'];

  final String workspaceDir;
  final int maxPreviewBytes;
  final int maxScannedFiles;

  new({required this.workspaceDir, this.maxPreviewBytes = 16 * 1024, this.maxScannedFiles = 200});

  Future<List<KnowledgeInboxItem>> list({String query = '', int limit = 20}) async {
    if (limit < 1 || maxScannedFiles < 1 || maxPreviewBytes < 1) {
      return const [];
    }
    final terms = _queryTerms(query);
    final candidates = <_InboxReadCandidate>[];
    final items = <KnowledgeInboxItem>[];
    for (final folder in folders) {
      final dir = Directory(p.join(workspaceDir, folder));
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final extension = p.extension(entity.path).toLowerCase();
        if (!KnowledgeInboxService.supportedExtensions.contains(extension)) continue;
        candidates.add(_InboxReadCandidate(file: entity, folder: folder, modified: (await entity.stat()).modified));
        if (candidates.length >= maxScannedFiles) break;
      }
      if (candidates.length >= maxScannedFiles) break;
    }
    candidates.sort((a, b) {
      final modifiedOrder = b.modified.compareTo(a.modified);
      if (modifiedOrder != 0) {
        return modifiedOrder;
      }
      final aLocator = p.join(a.folder, p.basename(a.file.path));
      final bLocator = p.join(b.folder, p.basename(b.file.path));
      return aLocator.compareTo(bLocator);
    });
    for (final candidate in candidates) {
      if (items.length >= limit) break;
      final entity = candidate.file;
      final body = await _readPreview(entity);
      final haystack = '${p.basename(entity.path)}\n$body'.toLowerCase();
      if (terms.isNotEmpty && !terms.every(haystack.contains)) continue;
      final locator = p.join(candidate.folder, p.basename(entity.path));
      items.add(
        KnowledgeInboxItem(
          locator: locator,
          label: p.basename(entity.path),
          folder: candidate.folder,
          snippet: _snippet(body, terms),
          modified: candidate.modified,
        ),
      );
    }
    return items;
  }

  /// Returns whether [locator] names a current regular file owned by this layer.
  Future<bool> exists(String locator) async {
    final file = _fileForLocator(locator);
    return file != null && FileSystemEntity.typeSync(file.path, followLinks: false) == FileSystemEntityType.file;
  }

  /// Reads the current regular source owned by [locator], or `null` when missing.
  Future<String?> read(String locator) async {
    final file = _fileForLocator(locator);
    return file == null ? null : core.MemoryFileService.readRegularFile(file);
  }

  /// Whether [locator] has the stable native shape owned by this layer.
  static bool supportsLocator(String locator) {
    final normalized = locator.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.length == 2 &&
        folders.contains(segments.first) &&
        !segments.any((part) => part.isEmpty || part == '.' || part == '..') &&
        KnowledgeInboxService.supportedExtensions.contains(p.extension(segments.last).toLowerCase());
  }

  File? _fileForLocator(String locator) {
    final normalized = locator.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (!supportsLocator(locator)) return null;
    final root = Directory(p.absolute(workspaceDir));
    final file = File(p.normalize(p.joinAll([root.path, ...segments])));
    return p.isWithin(root.path, file.path) ? file : null;
  }

  static List<String> _queryTerms(String query) => query
      .replaceAll('"', ' ')
      .split(RegExp(r'\s+'))
      .map((term) => term.trim().toLowerCase())
      .where((term) => term.isNotEmpty)
      .toList();

  static String _snippet(String text, List<String> terms) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 220) return compact;
    if (terms.isEmpty) return compact.substring(0, 220);
    final lower = compact.toLowerCase();
    final first = terms.map(lower.indexOf).where((index) => index >= 0).fold<int?>(null, (best, index) {
      if (best == null || index < best) return index;
      return best;
    });
    final start = first == null ? 0 : (first - 70).clamp(0, compact.length);
    final end = (start + 220).clamp(0, compact.length);
    return compact.substring(start, end);
  }

  Future<String> _readPreview(File file) {
    return file.openRead(0, maxPreviewBytes).transform(const Utf8Decoder(allowMalformed: true)).join();
  }
}

final class _InboxReadCandidate {
  final File file;
  final String folder;
  final DateTime modified;

  const new({required this.file, required this.folder, required this.modified});
}

/// Read-only inbox item surfaced by [KnowledgeInboxReadService].
final class KnowledgeInboxItem {
  final String locator;
  final String label;
  final String folder;
  final String snippet;
  final DateTime modified;

  const new({
    required this.locator,
    required this.label,
    required this.folder,
    required this.snippet,
    required this.modified,
  });
}
