import 'dart:io';

final _pattern = RegExp(r'_workflow|workflowRunId|stepIndex');

void main(List<String> args) {
  final sourcePath = _argValue(args, '--source');
  final allowlistPath = _argValue(args, '--allowlist');
  if (sourcePath == null || allowlistPath == null) {
    stderr.writeln(
      'Usage: dart run dev/tools/fitness/check_task_executor_workflow_refs.dart '
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

  final normalizedSource = _canonicalize(sourceFile.path);
  final sourceLines = sourceFile.readAsLinesSync();
  final liveMatches = <_Match>[];
  for (var i = 0; i < sourceLines.length; i++) {
    final text = sourceLines[i];
    if (_pattern.hasMatch(text)) {
      liveMatches.add(_Match(i + 1, _stableIdentifier(text)));
    }
  }

  final allowlist = allowlistFile
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
      .map(_AllowlistEntry.parse)
      .toList(growable: false);

  final allowlistByIdentifier = {for (final entry in allowlist) entry.identifier: entry};
  final unexpected = <_Match>[];
  for (final match in liveMatches) {
    if (!allowlistByIdentifier.containsKey(match.identifier)) {
      unexpected.add(match);
    }
  }

  final liveIdentifiers = liveMatches.map((match) => match.identifier).toSet();
  final stale = <_AllowlistEntry>[
    for (final entry in allowlist)
      if (!liveIdentifiers.contains(entry.identifier)) entry,
  ];

  if (unexpected.isEmpty && stale.isEmpty) {
    stdout.writeln(
      'Fitness function passed: task_executor workflow references match the allowlist (${liveMatches.length} matches).',
    );
    return;
  }

  if (unexpected.isNotEmpty) {
    stderr.writeln('Unexpected workflow references in $normalizedSource:');
    for (final match in unexpected) {
      stderr.writeln('  ${match.line}: ${match.identifier}');
    }
  }
  if (stale.isNotEmpty) {
    stderr.writeln('Stale allowlist entries:');
    for (final entry in stale) {
      stderr.writeln('  ${entry.identifier} | ${entry.reason}');
    }
  }
  exitCode = 1;
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

String _canonicalize(String path) {
  try {
    return File(path).absolute.uri.normalizePath().toFilePath();
  } catch (_) {
    return path;
  }
}

String _stableIdentifier(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

class _Match {
  final int line;
  final String identifier;

  _Match(this.line, this.identifier);
}

class _AllowlistEntry {
  final String identifier;
  final String reason;

  _AllowlistEntry(this.identifier, this.reason);

  factory _AllowlistEntry.parse(String line) {
    final separator = line.indexOf('|');
    if (separator <= 0 || separator == line.length - 1) {
      throw FormatException('Invalid allowlist entry: $line');
    }
    final identifier = _stableIdentifier(line.substring(0, separator));
    final reason = line.substring(separator + 1).trim();
    if (reason.isEmpty) throw FormatException('Invalid allowlist entry: $line');
    return _AllowlistEntry(identifier, reason);
  }
}
