import 'dart:io';

import 'package:logging/logging.dart';

import 'worktree_manager.dart';

/// File-level change classification in a diff.
enum DiffFileStatus { added, modified, deleted, renamed }

/// A single hunk within a file diff.
class DiffHunk {
  final String header;
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> lines;

  const DiffHunk({
    required this.header,
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  Map<String, dynamic> toJson() => {
    'header': header,
    'oldStart': oldStart,
    'oldCount': oldCount,
    'newStart': newStart,
    'newCount': newCount,
    'lines': lines,
  };

  factory DiffHunk.fromJson(Map<String, dynamic> json) => DiffHunk(
    header: json['header'] as String,
    oldStart: json['oldStart'] as int,
    oldCount: json['oldCount'] as int,
    newStart: json['newStart'] as int,
    newCount: json['newCount'] as int,
    lines: (json['lines'] as List).cast<String>(),
  );
}

/// Per-file diff entry with stats and hunks.
class DiffFileEntry {
  final String path;
  final String? oldPath;
  final DiffFileStatus status;
  final int additions;
  final int deletions;
  final bool binary;
  final List<DiffHunk> hunks;

  const DiffFileEntry({
    required this.path,
    this.oldPath,
    required this.status,
    required this.additions,
    required this.deletions,
    this.binary = false,
    required this.hunks,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    if (oldPath != null) 'oldPath': oldPath,
    'status': status.name,
    'additions': additions,
    'deletions': deletions,
    if (binary) 'binary': true,
    'hunks': hunks.map((h) => h.toJson()).toList(),
  };

  factory DiffFileEntry.fromJson(Map<String, dynamic> json) => DiffFileEntry(
    path: json['path'] as String,
    oldPath: json['oldPath'] as String?,
    status: DiffFileStatus.values.byName(json['status'] as String),
    additions: json['additions'] as int,
    deletions: json['deletions'] as int,
    binary: json['binary'] as bool? ?? false,
    hunks: (json['hunks'] as List).map((h) => DiffHunk.fromJson(h as Map<String, dynamic>)).toList(),
  );
}

/// Structured diff result from comparing two git refs.
class DiffResult {
  final List<DiffFileEntry> files;
  final int totalAdditions;
  final int totalDeletions;
  final int filesChanged;

  const DiffResult({
    required this.files,
    required this.totalAdditions,
    required this.totalDeletions,
    required this.filesChanged,
  });

  Map<String, dynamic> toJson() => {
    'files': files.map((f) => f.toJson()).toList(),
    'totalAdditions': totalAdditions,
    'totalDeletions': totalDeletions,
    'filesChanged': filesChanged,
  };

  factory DiffResult.fromJson(Map<String, dynamic> json) => DiffResult(
    files: (json['files'] as List).map((f) => DiffFileEntry.fromJson(f as Map<String, dynamic>)).toList(),
    totalAdditions: json['totalAdditions'] as int,
    totalDeletions: json['totalDeletions'] as int,
    filesChanged: json['filesChanged'] as int,
  );
}

/// Generates structured diff data by running git commands.
class DiffGenerator {
  static final _log = Logger('DiffGenerator');

  final String _projectDir;
  final Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})
  _runProcess;

  DiffGenerator({
    required String projectDir,
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
    processRunner,
  }) : _projectDir = projectDir,
       _runProcess = processRunner ?? _defaultProcessRunner;

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    return Process.run(executable, arguments, workingDirectory: workingDirectory);
  }

  /// Generates a structured diff between [baseRef] and [branch].
  ///
  /// Uses three-dot diff (`baseRef...branch`) to show only changes introduced
  /// on the branch, not changes on base since branching.
  Future<DiffResult> generate({required String baseRef, required String branch, String? projectDir}) async {
    final workingDirectory = projectDir ?? _projectDir;

    // 1. Get file-level stats via numstat
    final numstatResult = await _runProcess('git', [
      'diff',
      '--numstat',
      '$baseRef...$branch',
    ], workingDirectory: workingDirectory);
    if (numstatResult.exitCode != 0) {
      throw WorktreeException(
        'git diff --numstat failed',
        gitStderr: (numstatResult.stderr as String).trim(),
        exitCode: numstatResult.exitCode,
      );
    }

    // 2. Get unified diff with hunks
    final unifiedResult = await _runProcess('git', [
      'diff',
      '-U3',
      '--no-color',
      '$baseRef...$branch',
    ], workingDirectory: workingDirectory);
    if (unifiedResult.exitCode != 0) {
      throw WorktreeException(
        'git diff -U3 failed',
        gitStderr: (unifiedResult.stderr as String).trim(),
        exitCode: unifiedResult.exitCode,
      );
    }

    final numstatEntries = _parseNumstat((numstatResult.stdout as String).trim());
    final hunksByFile = _parseUnifiedDiff((unifiedResult.stdout as String));

    // 3. Correlate numstat with hunks
    final files = <DiffFileEntry>[];
    var totalAdditions = 0;
    var totalDeletions = 0;

    for (final entry in numstatEntries) {
      final hunks = hunksByFile[entry.path] ?? hunksByFile[entry.oldPath] ?? const <DiffHunk>[];
      files.add(
        DiffFileEntry(
          path: entry.path,
          oldPath: entry.oldPath,
          status: entry.status,
          additions: entry.additions,
          deletions: entry.deletions,
          binary: entry.binary,
          hunks: hunks,
        ),
      );
      totalAdditions += entry.additions;
      totalDeletions += entry.deletions;
    }

    _log.info(
      'Diff generated: ${files.length} files, '
      '+$totalAdditions/-$totalDeletions',
    );

    return DiffResult(
      files: files,
      totalAdditions: totalAdditions,
      totalDeletions: totalDeletions,
      filesChanged: files.length,
    );
  }

  List<_NumstatEntry> _parseNumstat(String output) {
    if (output.isEmpty) return const [];

    final entries = <_NumstatEntry>[];
    for (final line in output.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length < 3) continue;

      final addStr = parts[0];
      final delStr = parts[1];
      final pathPart = parts.sublist(2).join('\t');

      // Binary files: numstat reports - for additions and deletions
      if (addStr == '-' && delStr == '-') {
        entries.add(
          _NumstatEntry(path: pathPart, additions: 0, deletions: 0, binary: true, status: DiffFileStatus.modified),
        );
        continue;
      }

      final additions = int.tryParse(addStr) ?? 0;
      final deletions = int.tryParse(delStr) ?? 0;

      // Detect renames: path contains '{old => new}' or has a tab separator
      String path;
      String? oldPath;
      DiffFileStatus status;

      if (pathPart.contains('=>')) {
        final renameParts = _parseRenamePath(pathPart);
        path = renameParts.newPath;
        oldPath = renameParts.oldPath;
        status = DiffFileStatus.renamed;
      } else {
        path = pathPart;
        // Heuristic: if only additions (no deletions) it's likely added;
        // if only deletions it's likely deleted. Otherwise modified.
        // The unified diff has more reliable detection, but numstat is
        // our primary source. We'll refine via hunk parsing if needed.
        if (deletions == 0 && additions > 0) {
          status = DiffFileStatus.added;
        } else if (additions == 0 && deletions > 0) {
          status = DiffFileStatus.deleted;
        } else {
          status = DiffFileStatus.modified;
        }
      }

      entries.add(
        _NumstatEntry(path: path, oldPath: oldPath, additions: additions, deletions: deletions, status: status),
      );
    }
    return entries;
  }

  static final _hunkHeaderRe = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');
  static final _diffFileRe = RegExp(r'^diff --git a/(.*) b/(.*)$');

  Map<String, List<DiffHunk>> _parseUnifiedDiff(String output) {
    final hunksByFile = <String, List<DiffHunk>>{};
    if (output.trim().isEmpty) return hunksByFile;

    String? currentFile;
    final lines = output.split('\n');
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];

      // Detect new file header
      final fileMatch = _diffFileRe.firstMatch(line);
      if (fileMatch != null) {
        currentFile = fileMatch.group(2)!;
        hunksByFile.putIfAbsent(currentFile, () => []);
        i++;
        continue;
      }

      // Detect hunk header
      final hunkMatch = _hunkHeaderRe.firstMatch(line);
      if (hunkMatch != null && currentFile != null) {
        final oldStart = int.parse(hunkMatch.group(1)!);
        final oldCount = int.tryParse(hunkMatch.group(2) ?? '1') ?? 1;
        final newStart = int.parse(hunkMatch.group(3)!);
        final newCount = int.tryParse(hunkMatch.group(4) ?? '1') ?? 1;
        final header = line;

        // Collect hunk lines until next hunk or file header
        final hunkLines = <String>[];
        i++;
        while (i < lines.length) {
          final hunkLine = lines[i];
          if (hunkLine.startsWith('diff --git ') || _hunkHeaderRe.hasMatch(hunkLine)) {
            break;
          }
          if (hunkLine.startsWith(' ') ||
              hunkLine.startsWith('+') ||
              hunkLine.startsWith('-') ||
              hunkLine.startsWith('\\')) {
            hunkLines.add(hunkLine);
          }
          i++;
        }

        hunksByFile[currentFile]!.add(
          DiffHunk(
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: hunkLines,
          ),
        );
        continue;
      }

      i++;
    }

    return hunksByFile;
  }

  ({String oldPath, String newPath}) _parseRenamePath(String pathPart) {
    // Handle {old => new} format: e.g., 'src/{old.dart => new.dart}'
    final braceMatch = RegExp(r'^(.*)\{(.*) => (.*)\}(.*)$').firstMatch(pathPart);
    if (braceMatch != null) {
      final prefix = braceMatch.group(1)!;
      final oldSuffix = braceMatch.group(2)!;
      final newSuffix = braceMatch.group(3)!;
      final postfix = braceMatch.group(4)!;
      return (oldPath: '$prefix$oldSuffix$postfix', newPath: '$prefix$newSuffix$postfix');
    }
    // Fallback: tab-separated old\tnew
    final tabIndex = pathPart.indexOf('\t');
    if (tabIndex > 0) {
      return (oldPath: pathPart.substring(0, tabIndex), newPath: pathPart.substring(tabIndex + 1));
    }
    return (oldPath: pathPart, newPath: pathPart);
  }
}

class _NumstatEntry {
  final String path;
  final String? oldPath;
  final int additions;
  final int deletions;
  final bool binary;
  final DiffFileStatus status;

  const _NumstatEntry({
    required this.path,
    this.oldPath,
    required this.additions,
    required this.deletions,
    this.binary = false,
    required this.status,
  });
}
