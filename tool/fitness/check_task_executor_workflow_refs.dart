import 'dart:io';

final _pattern = RegExp(r'_workflow|workflowRunId|stepIndex');

void main(List<String> args) {
  final sourcePath = _argValue(args, '--source');
  final allowlistPath = _argValue(args, '--allowlist');
  if (sourcePath == null || allowlistPath == null) {
    stderr.writeln(
      'Usage: dart run tool/fitness/check_task_executor_workflow_refs.dart '
      '--source <path> --allowlist <path>',
    );
    exitCode = 64;
    return;
  }

  final sourceFile = File(sourcePath);
  final allowlistFile = File(allowlistPath);
  if (!sourceFile.existsSync()) {
    stderr.writeln('Source file not found: $sourcePath');
    exitCode = 66;
    return;
  }
  if (!allowlistFile.existsSync()) {
    stderr.writeln('Allowlist file not found: $allowlistPath');
    exitCode = 66;
    return;
  }

  final normalizedSource = sourceFile.path;
  final sourceLines = sourceFile.readAsLinesSync();
  final liveMatches = <_Match>[];
  for (var i = 0; i < sourceLines.length; i++) {
    final text = sourceLines[i];
    if (_pattern.hasMatch(text)) {
      liveMatches.add(_Match(normalizedSource, i + 1, text.trimRight()));
    }
  }

  final allowlist = allowlistFile
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
      .map(_AllowlistEntry.parse)
      .toList(growable: false);

  final unexpected = <_Match>[];
  for (final match in liveMatches) {
    if (!_isAllowed(match, allowlist)) {
      unexpected.add(match);
    }
  }

  final stale = <_AllowlistEntry>[];
  for (final entry in allowlist) {
    if (!_hasNearbyMatch(entry, liveMatches)) {
      stale.add(entry);
    }
  }

  if (unexpected.isEmpty && stale.isEmpty) {
    stdout.writeln(
      'Fitness function passed: task_executor workflow references match the allowlist (${liveMatches.length} matches).',
    );
    return;
  }

  if (unexpected.isNotEmpty) {
    stderr.writeln('Unexpected workflow references in $normalizedSource:');
    for (final match in unexpected) {
      stderr.writeln('  ${match.line}: ${match.text}');
    }
  }
  if (stale.isNotEmpty) {
    stderr.writeln('Stale allowlist entries:');
    for (final entry in stale) {
      stderr.writeln('  ${entry.path}:${entry.line}: ${entry.reason}');
    }
  }
  exitCode = 1;
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

bool _isAllowed(_Match match, List<_AllowlistEntry> allowlist) =>
    allowlist.any((entry) => entry.path == match.path && (entry.line - match.line).abs() <= 3);

bool _hasNearbyMatch(_AllowlistEntry entry, List<_Match> matches) =>
    matches.any((match) => match.path == entry.path && (entry.line - match.line).abs() <= 3);

class _Match {
  final String path;
  final int line;
  final String text;

  _Match(this.path, this.line, this.text);
}

class _AllowlistEntry {
  final String path;
  final int line;
  final String reason;

  _AllowlistEntry(this.path, this.line, this.reason);

  factory _AllowlistEntry.parse(String line) {
    final parts = line.split(':');
    if (parts.length < 3) {
      throw FormatException('Invalid allowlist entry: $line');
    }
    final path = parts.sublist(0, parts.length - 2).join(':');
    final lineNumber = int.parse(parts[parts.length - 2]);
    final reason = parts.last;
    return _AllowlistEntry(path, lineNumber, reason);
  }
}
