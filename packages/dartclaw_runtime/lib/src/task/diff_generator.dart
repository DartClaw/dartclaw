import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import 'host_worktree_git.dart';
import 'worktree_manager.dart';

/// File-level change classification in a diff.
enum DiffFileStatus { added, modified, deleted, renamed }

/// Metadata for one branch, worktree, or untracked change.
typedef DiffFileChange = ({String path, String? oldPath, DiffFileStatus status, bool isSymlink});

/// A single hunk within a file diff.
class DiffHunk {
  final String header;
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> lines;

  const new({
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

  factory fromJson(Map<String, dynamic> json) => DiffHunk(
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

  const new({
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

  factory fromJson(Map<String, dynamic> json) => DiffFileEntry(
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

  const new({
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

  factory fromJson(Map<String, dynamic> json) => DiffResult(
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
  final GitRunner _runGit;

  new({required String projectDir, GitRunner? processRunner})
    : _projectDir = projectDir,
      _runGit = processRunner ?? runGit;

  // User-visible git under the documented automation-owned/user-visible split:
  // review diffs must render what the operator's own git renders, so system
  // git config (diff/textconv drivers) stays in band.
  Future<ProcessResult> _git(List<String> arguments, {String? workingDirectory}) =>
      _runGit(arguments, workingDirectory: workingDirectory, noSystemConfig: false);

  /// Generates a structured diff for [branch] relative to [baseRef].
  ///
  /// Includes both committed branch changes (`baseRef...branch`) and current
  /// worktree changes so review/publish flows can see files that have not yet
  /// been committed by the agent.
  Future<DiffResult> generate({required String baseRef, required String branch, String? projectDir}) async {
    final workingDirectory = projectDir ?? _projectDir;

    final filesByPath = <String, DiffFileEntry>{};

    for (final revisionRange in ['$baseRef...$branch', 'HEAD']) {
      final numstat = await _gitDiffNumstat(revisionRange, workingDirectory: workingDirectory);
      final changes = await _gitDiffChanges(revisionRange, workingDirectory: workingDirectory, automated: false);
      final hunks = await _gitDiffUnified(revisionRange, workingDirectory: workingDirectory);
      _mergeEntries(
        filesByPath,
        _parseNumstat(numstat, {for (final change in changes) change.path: change}),
        _parseUnifiedDiff(hunks),
      );
    }

    final untrackedPaths = await _gitUntrackedFiles(workingDirectory: workingDirectory);
    for (final relativePath in untrackedPaths) {
      _mergeEntry(
        filesByPath,
        DiffFileEntry(
          path: relativePath,
          status: DiffFileStatus.added,
          additions: _countFileLines(workingDirectory, relativePath),
          deletions: 0,
          hunks: const [],
        ),
      );
    }

    final files = filesByPath.values.toList()..sort((a, b) => a.path.compareTo(b.path));
    final totalAdditions = files.fold<int>(0, (sum, file) => sum + file.additions);
    final totalDeletions = files.fold<int>(0, (sum, file) => sum + file.deletions);

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

  /// Reads the branch/worktree union without content or external diff drivers.
  ///
  /// Each source retains its own metadata, so an uncommitted deletion cannot
  /// conceal a symlink still present in the branch that would be merged.
  /// Set [includeWorktree] false when [projectDir] only supplies the repository
  /// for a branch with no checkout; its unrelated dirty files will not be swept.
  /// Set [fromMergeBase] false to compare the supplied Git trees directly.
  /// Git failures and malformed NUL framing throw [WorktreeException].
  Future<List<DiffFileChange>> changes({
    required String baseRef,
    required String branch,
    String? projectDir,
    bool includeWorktree = true,
    bool fromMergeBase = true,
  }) async {
    final workingDirectory = projectDir ?? _projectDir;
    final changes = <DiffFileChange>[];
    for (final revisionRange in [
      fromMergeBase ? '$baseRef...$branch' : '$baseRef..$branch',
      if (includeWorktree) 'HEAD',
    ]) {
      changes.addAll(await _gitDiffChanges(revisionRange, workingDirectory: workingDirectory, automated: true));
    }
    if (!includeWorktree) return changes;
    for (final path in await _gitUntrackedFiles(workingDirectory: workingDirectory, automated: true)) {
      final type = FileSystemEntity.typeSync('$workingDirectory${Platform.pathSeparator}$path', followLinks: false);
      if (type == FileSystemEntityType.notFound) throw WorktreeException('Changed file disappeared: $path');
      changes.add((
        path: path,
        oldPath: null,
        status: DiffFileStatus.added,
        isSymlink: type == FileSystemEntityType.link,
      ));
    }
    return changes;
  }

  Future<String> _gitDiffNumstat(String revisionRange, {required String workingDirectory}) async {
    final result = await _git(['diff', '--numstat', '-z', revisionRange], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw WorktreeException(
        'git diff --numstat failed',
        gitStderr: (result.stderr as String).trim(),
        exitCode: result.exitCode,
      );
    }
    return result.stdout as String;
  }

  Future<List<DiffFileChange>> _gitDiffChanges(
    String revisionRange, {
    required String workingDirectory,
    required bool automated,
  }) async {
    final result = await _runGit(
      [
        if (automated) ...hostWorktreeGitOptions,
        'diff',
        '--raw',
        '--no-abbrev',
        '--no-ext-diff',
        '--no-textconv',
        '-z',
        revisionRange,
      ],
      workingDirectory: workingDirectory,
      noSystemConfig: automated,
    );
    if (result.exitCode != 0) {
      throw WorktreeException(
        'git diff --raw failed',
        gitStderr: (result.stderr as String).trim(),
        exitCode: result.exitCode,
      );
    }
    return _parseRawDiff(result.stdout as String);
  }

  Future<String> _gitDiffUnified(String revisionRange, {required String workingDirectory}) async {
    final result = await _git(['diff', '-U3', '--no-color', revisionRange], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw WorktreeException(
        'git diff -U3 failed',
        gitStderr: (result.stderr as String).trim(),
        exitCode: result.exitCode,
      );
    }
    return result.stdout as String;
  }

  Future<List<String>> _gitUntrackedFiles({required String workingDirectory, bool automated = false}) async {
    final result = await _runGit(
      [if (automated) ...hostWorktreeGitOptions, 'ls-files', '--others', '--exclude-standard', '-z'],
      workingDirectory: workingDirectory,
      noSystemConfig: automated,
    );
    if (result.exitCode != 0) {
      throw WorktreeException(
        'git ls-files --others failed',
        gitStderr: (result.stderr as String).trim(),
        exitCode: result.exitCode,
      );
    }

    return _nulFields(result.stdout as String);
  }

  int _countFileLines(String workingDirectory, String relativePath) {
    final file = File('$workingDirectory${Platform.pathSeparator}$relativePath');
    if (!file.existsSync()) {
      return 0;
    }
    return file.readAsLinesSync().length;
  }

  void _mergeEntries(
    Map<String, DiffFileEntry> filesByPath,
    List<_NumstatEntry> entries,
    Map<String, List<DiffHunk>> hunksByFile,
  ) {
    for (final entry in entries) {
      final hunks = hunksByFile[entry.path] ?? hunksByFile[entry.oldPath] ?? const <DiffHunk>[];
      _mergeEntry(
        filesByPath,
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
    }
  }

  void _mergeEntry(Map<String, DiffFileEntry> filesByPath, DiffFileEntry entry) {
    final existing = filesByPath[entry.path];
    if (existing == null) {
      filesByPath[entry.path] = entry;
      return;
    }

    filesByPath[entry.path] = DiffFileEntry(
      path: entry.path,
      oldPath: entry.oldPath ?? existing.oldPath,
      status: _mergeStatus(existing.status, entry.status),
      additions: existing.additions + entry.additions,
      deletions: existing.deletions + entry.deletions,
      binary: existing.binary || entry.binary,
      hunks: [...existing.hunks, ...entry.hunks],
    );
  }

  DiffFileStatus _mergeStatus(DiffFileStatus existing, DiffFileStatus incoming) {
    if (existing == incoming) {
      return existing;
    }
    if (incoming == DiffFileStatus.renamed || existing == DiffFileStatus.renamed) {
      return DiffFileStatus.renamed;
    }
    if (incoming == DiffFileStatus.added || existing == DiffFileStatus.added) {
      return DiffFileStatus.added;
    }
    return DiffFileStatus.modified;
  }

  List<DiffFileChange> _parseRawDiff(String output) {
    final fields = _nulFields(output);
    final changes = <DiffFileChange>[];
    for (var i = 0; i < fields.length; i++) {
      final header = _rawHeader.firstMatch(fields[i]);
      if (header == null) throw const WorktreeException('Malformed git diff --raw metadata');
      final code = header.group(3)!;
      final renamed = code.startsWith('R') || code.startsWith('C');
      final count = renamed ? 2 : 1;
      if (i + count >= fields.length) throw const WorktreeException('Truncated git diff --raw paths');
      final oldPath = renamed ? fields[i + 1] : null;
      final path = fields[i + count];
      changes.add((
        path: path,
        oldPath: oldPath,
        status: code.startsWith('R') ? DiffFileStatus.renamed : _statusForCode(code),
        isSymlink: header.group(2) == '120000',
      ));
      i += count;
    }
    return changes;
  }

  static final _rawHeader = RegExp(r'^:([0-7]{6}) ([0-7]{6}) [0-9a-f]+ [0-9a-f]+ ([ACDMRT][0-9]*)$');

  static DiffFileStatus _statusForCode(String code) => switch (code[0]) {
    'A' || 'C' => DiffFileStatus.added,
    'D' => DiffFileStatus.deleted,
    _ => DiffFileStatus.modified,
  };

  /// Decodes `git diff --numstat -z` into per-file counts, taking each file's
  /// status and rename source from [statusByPath].
  ///
  /// A rename record carries an empty path field followed by the pre- and
  /// post-image paths, so no `{old => new}` syntax is ever decoded here.
  List<_NumstatEntry> _parseNumstat(String output, Map<String, DiffFileChange> statusByPath) {
    final fields = _nulFields(output);
    final entries = <_NumstatEntry>[];
    for (var i = 0; i < fields.length; i++) {
      final parts = fields[i].split('\t');
      if (parts.length < 3) continue;

      String path;
      if (parts.length == 3 && parts[2].isEmpty) {
        if (i + 2 >= fields.length) break;
        path = fields[i + 2];
        i += 2;
      } else {
        path = parts.sublist(2).join('\t');
      }

      final recorded = statusByPath[path];
      final binary = parts[0] == '-' && parts[1] == '-';
      entries.add(
        _NumstatEntry(
          path: path,
          oldPath: recorded?.oldPath,
          additions: binary ? 0 : int.tryParse(parts[0]) ?? 0,
          deletions: binary ? 0 : int.tryParse(parts[1]) ?? 0,
          binary: binary,
          status: recorded?.status ?? DiffFileStatus.modified,
        ),
      );
    }
    return entries;
  }

  /// The NUL-terminated records in git's `-z` output, without the trailing
  /// empty field the final terminator leaves behind.
  static List<String> _nulFields(String output) {
    if (output.isEmpty) return [];
    if (!output.endsWith('\u0000')) throw const WorktreeException('Truncated NUL-framed git metadata');
    final fields = output.split('\u0000')..removeLast();
    if (fields.any((field) => field.isEmpty)) throw const WorktreeException('Empty field in git metadata');
    return fields;
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
}

class _NumstatEntry {
  final String path;
  final String? oldPath;
  final int additions;
  final int deletions;
  final bool binary;
  final DiffFileStatus status;

  const new({
    required this.path,
    this.oldPath,
    required this.additions,
    required this.deletions,
    this.binary = false,
    required this.status,
  });
}
