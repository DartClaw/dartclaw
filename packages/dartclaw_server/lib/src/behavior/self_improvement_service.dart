import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        CanonicalMemoryCorpus,
        CanonicalMemoryLearning,
        MemoryCorpusChange,
        MemoryCorpusFileMutation,
        MemoryCorpusMutation,
        MemoryCorpusService,
        MemoryFileService,
        MemoryLearningDocument,
        MemoryMarkdownCodec,
        MemoryRole,
        MemorySourceRef,
        parseMemoryEntries,
        secureWriteFileSync;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class _WriteOp {
  final Future<void> Function() run;

  _WriteOp(this.run);
}

/// Manages `errors.md` and `learnings.md` in the workspace.
///
/// `errors.md` is auto-populated on turn failures, guard blocks, and crashes.
/// `learnings.md` is written through the canonical learning capture role.
/// Both are capped at [maxEntries] entries (oldest trimmed on write).
class SelfImprovementService {
  static final _log = Logger('SelfImprovementService');

  final String workspaceDir;
  final int maxEntries;
  final MemoryCorpusService _corpusService;
  final bool _ownsCorpusService;
  final String Function() _createId;
  String? _resolvedWorkspaceDir;

  final _queue = StreamController<_WriteOp>();
  late final StreamSubscription<void> _queueSub;

  SelfImprovementService({
    required this.workspaceDir,
    this.maxEntries = 50,
    MemoryCorpusService? corpusService,
    String Function()? createId,
  }) : _corpusService = corpusService ?? MemoryCorpusService(workspaceDir: workspaceDir),
       _ownsCorpusService = corpusService == null,
       _createId = createId ?? const Uuid().v4 {
    _queueSub = _queue.stream.asyncMap((op) => op.run()).listen((_) {});
  }

  String? get _errorsPath => _workspacePath('errors.md', createWorkspace: false);
  String? get _learningsPath => _workspacePath('learnings.md', createWorkspace: false);

  /// Appends an error entry to `errors.md`. Never throws — logs warnings on failure.
  Future<void> appendError({
    required String errorType,
    required String sessionId,
    required String context,
    String? resolution,
  }) {
    return _enqueue(() async {
      try {
        final timestamp = DateTime.now().toUtc().toIso8601String();
        final buf = StringBuffer()
          ..writeln('## [$timestamp] ${_encodeContinuations(errorType)}')
          ..writeln('- Session: ${_encodeContinuations(sessionId)}')
          ..writeln('- Context: ${_encodeContinuations(context)}');
        if (resolution != null) {
          buf.writeln('- Resolution: ${_encodeContinuations(resolution)}');
        }
        buf.writeln();

        final path = _workspacePath('errors.md', createWorkspace: true)!;
        await _appendCapped(path, buf.toString(), '## [');
      } catch (e) {
        _log.warning('Failed to write errors.md: $e');
      }
    });
  }

  /// Appends a learning entry to `learnings.md`.
  ///
  /// Uses [timestamp] when provided. [afterWrite] runs with the complete retained
  /// content before the workspace memory lock is released. Write failures are
  /// propagated to the caller.
  Future<void> appendLearning({
    required String text,
    DateTime? timestamp,
    FutureOr<void> Function(String retainedContent)? afterWrite,
  }) {
    if (!_ownsCorpusService) return _appendCanonicalLearning(text, timestamp, afterWrite);
    return _corpusService
        .updateFiles<String>(
          paths: const ['learnings.md'],
          prepare: (files) {
            final writtenAt = timestamp ?? DateTime.now();
            final formattedTimestamp = writtenAt.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
            final entry = '- [$formattedTimestamp] ${_encodeContinuations(text)}\n';
            final bytes = files['learnings.md'];
            final retained = _appendCappedLearnings(bytes == null ? '' : utf8.decode(bytes), entry, maxEntries);
            return MemoryCorpusFileMutation(value: retained, writes: {'learnings.md': utf8.encode(retained)});
          },
          prepareCanonical: (corpus) => _canonicalLearningMutation(corpus, text, timestamp),
          bootstrapCanonical: !_ownsCorpusService,
          afterCommit: afterWrite,
        )
        .then<void>((_) {});
  }

  Future<void> _appendCanonicalLearning(
    String text,
    DateTime? timestamp,
    FutureOr<void> Function(String retainedContent)? afterWrite,
  ) async {
    while (true) {
      final manifest = await _corpusService.manifest();
      final result = await _corpusService.changeSelected<String>(
        expectedRevision: manifest.collectionRevision,
        include: (role, _) => role == MemoryRole.learning,
        prepare: (corpus) {
          final mutation = _canonicalLearningMutation(corpus, text, timestamp);
          return MemoryCorpusChange(value: mutation.value, replacement: mutation.corpus);
        },
        afterCommit: (retained, _) => afterWrite?.call(retained),
      );
      if (!result.wasStale) return;
    }
  }

  MemoryCorpusMutation<String> _canonicalLearningMutation(
    CanonicalMemoryCorpus corpus,
    String text,
    DateTime? timestamp,
  ) {
    final writtenAt = (timestamp ?? DateTime.now()).toUtc();
    final content = text.trim();
    final prior = corpus.learnings?.entries ?? const <CanonicalMemoryLearning>[];
    final newEntry = CanonicalMemoryLearning(
      id: _createId(),
      revision: 1,
      summary: content.split('\n').first,
      content: content,
      created: writtenAt,
      updated: writtenAt,
      provenance: MemorySourceRef(sourceLocator: 'runtime-learning'),
    );
    final existingLimit = maxEntries - 1;
    final retained = maxEntries <= 0
        ? const <CanonicalMemoryLearning>[]
        : [...prior.skip(prior.length > existingLimit ? prior.length - existingLimit : 0), newEntry];
    final document = MemoryLearningDocument(entries: retained);
    return MemoryCorpusMutation(
      value: const MemoryMarkdownCodec().render(document),
      corpus: CanonicalMemoryCorpus(
        index: corpus.index,
        topics: corpus.topics,
        archive: corpus.archive,
        observations: corpus.observations,
        learnings: document,
        audit: corpus.audit,
        verbatimMembers: corpus.verbatimMembers,
      ),
    );
  }

  /// Returns errors.md contents, or empty string if missing.
  Future<String> readErrors() async {
    try {
      final path = _errorsPath;
      if (path == null) return '';
      return MemoryFileService.readRegularFile(File(path)) ?? '';
    } catch (e) {
      _log.warning('Failed to read errors.md: $e');
    }
    return '';
  }

  /// Returns learnings.md contents, or empty string if missing.
  Future<String> readLearnings() async {
    try {
      final path = _learningsPath;
      if (path == null) return '';
      return MemoryFileService.readRegularFile(File(path)) ?? '';
    } catch (e) {
      _log.warning('Failed to read learnings.md: $e');
    }
    return '';
  }

  /// Appends [entry] to [filePath], capping at [maxEntries].
  /// [entryPrefix] is used to identify entry boundaries when parsing.
  Future<String> _appendCapped(String filePath, String entry, String entryPrefix) async {
    final file = File(filePath);
    final dir = file.parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final content = MemoryFileService.readRegularFile(file);
    if (content == null) {
      secureWriteFileSync(file, entry, restrictPermissions: false);
      return entry;
    }
    if (entryPrefix == '- [') {
      final retained = _appendCappedLearnings(content, entry, maxEntries);
      secureWriteFileSync(file, retained, restrictPermissions: false);
      return retained;
    }

    final entries = _parseEntries(content, entryPrefix);
    entries.add(entry);

    // Trim oldest entries if over cap
    while (entries.length > maxEntries) {
      entries.removeAt(0);
    }

    final retained = entries.join();
    secureWriteFileSync(file, retained, restrictPermissions: false);
    return retained;
  }

  static String _appendCappedLearnings(String content, String entry, int maxEntries) {
    final entries = parseMemoryEntries(content)
        .where(
          (candidate) => candidate.timestamp != null && candidate.sourceStart != null && candidate.sourceEnd != null,
        )
        .toList(growable: false);
    var removeCount = maxEntries <= 0 ? entries.length : entries.length + 1 - maxEntries;
    if (removeCount < 0) removeCount = 0;
    if (removeCount > entries.length) removeCount = entries.length;

    final retained = StringBuffer();
    var offset = 0;
    for (final candidate in entries.take(removeCount)) {
      final start = candidate.sourceStart!;
      var end = candidate.sourceEnd!;
      if (end < content.length && content.codeUnitAt(end) == 0x0A) end++;
      retained.write(content.substring(offset, start));
      offset = end;
    }
    retained.write(content.substring(offset));
    if (maxEntries <= 0) return retained.toString();
    if (retained.isNotEmpty && !retained.toString().endsWith('\n')) retained.writeln();
    retained.write(entry);
    return retained.toString();
  }

  /// Parses file content into individual entries based on [prefix].
  static List<String> _parseEntries(String content, String prefix) {
    if (content.trim().isEmpty) return [];

    final entries = <String>[];
    final lines = content.split('\n');
    final buf = StringBuffer();

    for (final line in lines) {
      if (line.startsWith(prefix) && buf.isNotEmpty) {
        entries.add(buf.toString());
        buf.clear();
      }
      buf.writeln(line);
    }
    if (buf.isNotEmpty) {
      entries.add(buf.toString());
    }

    return entries;
  }

  static String _encodeContinuations(String value) =>
      value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\n', '\n  ');

  String? _workspacePath(String name, {required bool createWorkspace}) {
    final root = _workspaceRoot(create: createWorkspace);
    return root == null ? null : p.join(root, name);
  }

  String? _workspaceRoot({required bool create}) {
    if (_resolvedWorkspaceDir case final resolved?) {
      _requireDirectory(resolved);
      return resolved;
    }
    final directory = Directory(p.absolute(workspaceDir));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return null;
      directory.createSync(recursive: true);
    } else if (type != FileSystemEntityType.directory && type != FileSystemEntityType.link) {
      throw FileSystemException('Workspace root is not a directory', directory.path);
    }
    final resolved = directory.resolveSymbolicLinksSync();
    _requireDirectory(resolved);
    return _resolvedWorkspaceDir = p.normalize(resolved);
  }

  static void _requireDirectory(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace root is not a directory', path);
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _queue.add(
      _WriteOp(() async {
        try {
          completer.complete(await fn());
        } catch (e, st) {
          completer.completeError(e, st);
        }
      }),
    );
    return completer.future;
  }

  Future<void> dispose() async {
    await _queue.close();
    await _queueSub.cancel();
    if (_ownsCorpusService) await _corpusService.close();
  }
}
