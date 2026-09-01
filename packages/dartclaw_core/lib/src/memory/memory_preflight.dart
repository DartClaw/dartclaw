import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show truncateUtf8Bytes;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Outcome of canonical memory startup preflight.
enum MemoryPreflightStatus {
  /// The canonical corpus was already current.
  alreadyCurrent,

  /// Supported stopped-runtime edits were reconciled.
  reconciled,
}

/// Prepares the canonical memory corpus before any derived index may open.
///
/// Reconciles supported stopped-runtime edits and publishes one bounded report
/// plus the manifest that gates index reconciliation. A workspace still holding
/// the retained preview memory dialect is refused rather than converted: no
/// release after [lastConvertingRelease] ships the converter, and a partial
/// conversion is worse than a refusal an operator can act on.
final class MemoryPreflight {
  /// Creates a preflight against [workspaceDir] using the shared corpus authority.
  new({required this.workspaceDir, required this.corpusService});

  /// Maximum diagnostics retained in a report.
  static const maxDiagnostics = 100;

  /// Maximum UTF-8 report size.
  static const maxReportBytes = 64 * 1024;

  /// Last release whose `dartclaw serve` converted the preview memory dialect.
  static const lastConvertingRelease = '0.24.2';

  /// Stage of a refusal raised by the preview-dialect detection.
  static const legacyDialectStage = 'legacy-dialect-detected';

  static final _legacyErrorHeader = RegExp(r'^## \[([^\]]*)\] ?(.*)$');
  static final _legacyErrorField = RegExp(r'^- (Session|Context|Resolution): ?(.*)$');

  /// Workspace containing the canonical corpus.
  final String workspaceDir;

  /// Shared canonical corpus mutation authority.
  final MemoryCorpusService corpusService;

  /// Reconciles and validates the corpus, or refuses a preview-dialect workspace.
  ///
  /// Throws [MemoryPreflightException] carrying a bounded operator report.
  Future<MemoryPreflightResult> preflight() async {
    try {
      return await _preflight();
    } on MemoryPreflightException {
      rethrow;
    } on Object catch (error) {
      throw MemoryPreflightException.bounded(stage: 'validate-classify-or-commit', error: error);
    }
  }

  Future<MemoryPreflightResult> _preflight() async {
    final root = Directory(p.absolute(workspaceDir));
    final memoryFile = File(p.join(root.path, 'MEMORY.md'));
    final hasCanonicalMarker = memoryFile.existsSync() && _hasCanonicalMarker(memoryFile);
    // `learnings.md`, `MEMORY.archive.md` and `memory/<date>.md` are canonical
    // member paths too, so the marker alone cannot tell a preview workspace from
    // a canonical one whose index was damaged. Corpus state settles it: only the
    // canonical authority writes it, and a damaged canonical workspace belongs to
    // that authority's recovery message, not to a downgrade instruction.
    if (!hasCanonicalMarker && !MemoryCorpusService.hasCanonicalState(workspaceDir: root.path)) {
      final detected = _legacySourcePaths(root)
          .where(
            (path) =>
                FileSystemEntity.typeSync(p.join(root.path, path), followLinks: false) != FileSystemEntityType.notFound,
          )
          .toList();
      if (detected.isNotEmpty) {
        throw MemoryPreflightException.bounded(
          stage: legacyDialectStage,
          error:
              'workspace ${root.path} still holds the preview memory dialect '
              '(${detected.join(', ')}). This release does not convert it. Complete the conversion by '
              'starting DartClaw $lastConvertingRelease once against this workspace, then upgrade again.',
        );
      }
    }

    _canonicalizeLegacyErrors(root);

    final snapshot = await corpusService.snapshot(
      paths: const ['MEMORY.md'],
      maxDocuments: 1,
      maxBytes: MemoryCorpusService.maxCorpusBytes,
    );
    return MemoryPreflightResult._(
      status: snapshot.externalChanges.isEmpty
          ? MemoryPreflightStatus.alreadyCurrent
          : MemoryPreflightStatus.reconciled,
      collectionRevision: snapshot.collectionRevision,
      fingerprint: snapshot.fingerprint,
      totalDiagnostics: snapshot.externalChanges.length,
      diagnostics: snapshot.externalChanges
          .take(maxDiagnostics)
          .map(
            (change) => _MemoryPreflightDiagnostic(
              role: change.role?.wireName ?? 'verbatim',
              locator: change.locator,
              reason: change.wasRemoved ? 'supported canonical member removed' : 'supported canonical member changed',
            ),
          ),
    );
  }

  /// Rewrites a pre-canonical `errors.md` into the canonical error role.
  ///
  /// `errors.md` joined the corpus in this release, so an existing workspace
  /// carries a legacy file at a member path the fail-closed authority would
  /// refuse to hydrate. No earlier release converts it, so refusing would strand
  /// every existing workspace; the rewrite lands before the authority scans and
  /// is reconciled as an ordinary stopped-runtime edit.
  static void _canonicalizeLegacyErrors(Directory root) {
    final file = File(p.join(root.path, 'errors.md'));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) return;
    if (_hasCanonicalMarker(file)) return;
    // Above the shared source ceiling the authority raises its own typed limit
    // failure; reading the file whole here would defeat that bound.
    if (file.lengthSync() > MemoryResourceLimits.sourceBytes) return;
    // A stray byte must not become a startup exit: strict decoding here would
    // leave the file unconverted at a member path the authority then refuses.
    final content = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    final parsed = _parseLegacyErrors(content, file.lastModifiedSync().toUtc());
    if (parsed.remainder.trim().isNotEmpty) {
      final preserved = File(_freeLegacyPath(root, 'errors.md'));
      preserved.parent.createSync(recursive: true);
      secureWriteFileSync(preserved, parsed.remainder, restrictPermissions: false);
    }
    secureWriteFileSync(
      file,
      const MemoryMarkdownCodec().render(MemoryErrorDocument(entries: parsed.records)),
      restrictPermissions: false,
    );
  }

  static String _freeLegacyPath(Directory root, String name) {
    final base = p.join(root.path, 'memory', 'legacy');
    var candidate = p.join(base, name);
    var ordinal = 1;
    while (FileSystemEntity.typeSync(candidate, followLinks: false) != FileSystemEntityType.notFound) {
      candidate = p.join(base, '${p.basenameWithoutExtension(name)}.$ordinal${p.extension(name)}');
      ordinal++;
    }
    return candidate;
  }

  static ({List<CanonicalMemoryError> records, String remainder}) _parseLegacyErrors(
    String content,
    DateTime fallback,
  ) {
    final records = <CanonicalMemoryError>[];
    final remainder = StringBuffer();
    final blocks = <({String header, List<String> lines})>[];
    for (final line in const LineSplitter().convert(content)) {
      final match = _legacyErrorHeader.firstMatch(line);
      if (match != null) {
        blocks.add((header: line, lines: <String>[]));
      } else if (blocks.isEmpty) {
        remainder.writeln(line);
      } else {
        blocks.last.lines.add(line);
      }
    }
    for (final (index, block) in blocks.indexed) {
      final match = _legacyErrorHeader.firstMatch(block.header)!;
      final recorded = DateTime.tryParse(match.group(1)!)?.toUtc() ?? fallback;
      final fields = _legacyFields(match.group(2)!, block.lines);
      final body = [
        fields['Context'] ?? '',
        if ((fields['Resolution'] ?? '').isNotEmpty) 'Resolution: ${fields['Resolution']}',
      ].where((part) => part.isNotEmpty).join('\n\n');
      final summary = (fields['Type'] ?? '').isEmpty ? 'UNKNOWN' : fields['Type']!;
      final session = fields['Session'] ?? '';
      records.add(
        CanonicalMemoryError(
          id: const Uuid().v5(Namespace.url.value, 'dartclaw:errors.md:$index:${block.header}'),
          revision: 1,
          summary: summary,
          content: body.isEmpty ? summary : body,
          created: recorded,
          updated: recorded,
          provenance: MemorySourceRef(
            originKind: MemoryOriginKind.migration,
            sourceLocator: 'errors.md',
            sessionRef: session.isEmpty ? null : session,
          ),
        ),
      );
    }
    return (records: records, remainder: remainder.toString());
  }

  /// Splits one legacy block into its `- Name: value` fields, folding the
  /// writer's two-space continuation lines back into the field they extend.
  static Map<String, String> _legacyFields(String type, List<String> lines) {
    final fields = <String, String>{'Type': type};
    var current = 'Type';
    for (final line in lines) {
      final match = _legacyErrorField.firstMatch(line);
      if (match != null) {
        current = match.group(1)!;
        fields[current] = match.group(2)!;
      } else if (line.startsWith('  ')) {
        fields[current] = '${fields[current]}\n${line.substring(2)}';
      } else if (line.isNotEmpty) {
        fields[current] = '${fields[current]}\n$line';
      }
    }
    return {for (final entry in fields.entries) entry.key: entry.value.trim()};
  }

  static List<String> _legacySourcePaths(Directory root) {
    final paths = <String>['MEMORY.md', 'MEMORY.archive.md', 'learnings.md'];
    final memoryDir = Directory(p.join(root.path, 'memory'));
    if (!memoryDir.existsSync()) return paths;
    for (final entity in memoryDir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (RegExp(r'^\d{4}-\d{2}-\d{2}\.md$').hasMatch(name)) paths.add('memory/$name');
    }
    paths.sort();
    return paths;
  }

  static bool _hasCanonicalMarker(File file) {
    final handle = file.openSync();
    try {
      final head = utf8.decode(handle.readSync(64), allowMalformed: true);
      if (!head.startsWith(canonicalMemoryHeader)) return false;
      if (head.length == canonicalMemoryHeader.length) return true;
      final next = head[canonicalMemoryHeader.length];
      return next == '\n' || next == '\r';
    } finally {
      handle.closeSync();
    }
  }

  static String _failureReport(String stage, Object error) {
    final value =
        'Memory preflight: failed\n'
        'Stage: $stage\n'
        'Diagnostics: total=1 returned=1 omitted=0\n'
        'Recovery: $error\n';
    if (utf8.encode(value).length <= maxReportBytes) return value;
    return 'Memory preflight: failed\n'
        'Stage: $stage\n'
        'Diagnostics: total=1 returned=0 omitted=1\n'
        'Recovery: diagnostic omitted by the $maxReportBytes-byte report limit\n';
  }
}

final class _MemoryPreflightDiagnostic {
  const new({required this.role, required this.locator, required this.reason});

  final String role;
  final String locator;
  final String reason;
}

/// Result emitted before derived memory indexes may start.
final class MemoryPreflightResult {
  new _({
    required this.status,
    required this.collectionRevision,
    required this.fingerprint,
    required this.totalDiagnostics,
    required Iterable<_MemoryPreflightDiagnostic> diagnostics,
  }) : _diagnostics = List.unmodifiable(diagnostics);

  /// The preflight action that completed.
  final MemoryPreflightStatus status;

  /// Current canonical collection revision.
  final int collectionRevision;

  /// Fingerprint of the committed canonical corpus.
  final String fingerprint;

  /// Total diagnostics before count and byte truncation.
  final int totalDiagnostics;

  final List<_MemoryPreflightDiagnostic> _diagnostics;

  /// Number of diagnostics omitted by the count cap.
  int get omittedDiagnostics => totalDiagnostics - _diagnostics.length;

  /// Renders a UTF-8 report capped at 64 KiB and 100 diagnostics.
  String render() {
    final header = <String>[
      'Memory preflight: ${status.name}',
      'Collection revision: $collectionRevision',
      'Fingerprint: $fingerprint',
    ];
    var returned = _diagnostics.length;
    while (true) {
      final omitted = totalDiagnostics - returned;
      final lines = [
        ...header,
        'Diagnostics: total=$totalDiagnostics returned=$returned omitted=$omitted',
        for (final diagnostic in _diagnostics.take(returned))
          '[reconcile] ${diagnostic.role} ${diagnostic.locator}: ${diagnostic.reason}',
      ];
      final value = '${lines.join('\n')}\n';
      if (utf8.encode(value).length <= MemoryPreflight.maxReportBytes) return value;
      if (returned == 0) {
        return _utf8Prefix(value, MemoryPreflight.maxReportBytes);
      }
      returned--;
    }
  }
}

/// A failed preflight with a bounded recovery report.
final class MemoryPreflightException implements Exception {
  const new _(this.stage, this.report);

  /// Creates a failure carrying a bounded operator report.
  factory bounded({required String stage, required Object error}) =>
      MemoryPreflightException._(stage, MemoryPreflight._failureReport(stage, error));

  /// Preflight stage that failed; [MemoryPreflight.legacyDialectStage] is a refusal.
  final String stage;

  /// Bounded recovery report suitable for startup logging.
  final String report;

  @override
  String toString() => report;
}

String _utf8Prefix(String value, int maxBytes) => truncateUtf8Bytes(value, maxBytes);
