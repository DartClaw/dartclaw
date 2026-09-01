import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        CanonicalMemoryCorpus,
        CanonicalMemoryError,
        CanonicalMemoryLearning,
        MemoryCorpusChange,
        MemoryCorpusFileMutation,
        MemoryCorpusMutation,
        MemoryCorpusService,
        MemoryErrorDocument,
        MemoryFileService,
        MemoryLearningDocument,
        MemoryMarkdownCodec,
        MemoryRole,
        MemorySourceRef,
        parseMemoryEntries;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class _WriteOp {
  final Future<void> Function() run;

  new(this.run);
}

/// Manages `errors.md` and `learnings.md` in the workspace.
///
/// `errors.md` is auto-populated on turn failures, guard blocks, and crashes and
/// is written through the canonical error role. `learnings.md` is written
/// through the canonical learning capture role. Both are capped at [maxEntries]
/// entries (oldest trimmed on write).
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

  new({
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

  /// Records an error in the canonical corpus. Never throws — logs warnings on failure.
  Future<void> appendError({
    required String errorType,
    required String sessionId,
    required String context,
    String? resolution,
  }) {
    return _enqueue(() async {
      try {
        await _appendCanonicalError(
          errorType: errorType,
          sessionId: sessionId,
          context: context,
          resolution: resolution,
        );
      } catch (e) {
        _log.warning('Failed to write errors.md: $e');
      }
    });
  }

  Future<void> _appendCanonicalError({
    required String errorType,
    required String sessionId,
    required String context,
    required String? resolution,
  }) async {
    final recordedAt = DateTime.now().toUtc();
    while (true) {
      final manifest = await _corpusService.manifest();
      final result = await _corpusService.changeSelected<void>(
        expectedRevision: manifest.collectionRevision,
        include: (role, _) => role == MemoryRole.error,
        prepare: (corpus) => MemoryCorpusChange(
          value: null,
          replacement: _canonicalErrorCorpus(
            corpus,
            errorType: errorType,
            sessionId: sessionId,
            context: context,
            resolution: resolution,
            recordedAt: recordedAt,
          ),
        ),
      );
      if (!result.wasStale) return;
    }
  }

  CanonicalMemoryCorpus _canonicalErrorCorpus(
    CanonicalMemoryCorpus corpus, {
    required String errorType,
    required String sessionId,
    required String context,
    required String? resolution,
    required DateTime recordedAt,
  }) {
    final summary = errorType.trim().isEmpty ? 'UNKNOWN' : errorType.trim();
    final body = [
      context.trim(),
      if (resolution != null && resolution.trim().isNotEmpty) 'Resolution: ${resolution.trim()}',
    ].where((part) => part.isNotEmpty).join('\n\n');
    final session = sessionId.trim();
    final record = CanonicalMemoryError(
      id: _createId(),
      revision: 1,
      summary: summary,
      content: body.isEmpty ? summary : body,
      created: recordedAt,
      updated: recordedAt,
      provenance: MemorySourceRef(sourceLocator: 'runtime-error', sessionRef: session.isEmpty ? null : session),
    );
    final prior = corpus.errors?.entries ?? const <CanonicalMemoryError>[];
    final existingLimit = maxEntries - 1;
    final retained = maxEntries <= 0
        ? const <CanonicalMemoryError>[]
        : [...prior.skip(prior.length > existingLimit ? prior.length - existingLimit : 0), record];
    return CanonicalMemoryCorpus(
      index: corpus.index,
      topics: corpus.topics,
      archive: corpus.archive,
      observations: corpus.observations,
      learnings: corpus.learnings,
      errors: MemoryErrorDocument(entries: retained),
      audit: corpus.audit,
      verbatimMembers: corpus.verbatimMembers,
    );
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
        errors: corpus.errors,
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
