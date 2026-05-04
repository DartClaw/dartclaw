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
      liveMatches.add(_Match(normalizedSource, i + 1, text.trimRight()));
    }
  }

  final allowlist = allowlistFile
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
      .map((line) => _AllowlistEntry.parse(line, _canonicalize))
      .toList(growable: false);

  // Pair each live match to at most one allowlist entry within ±3 lines, choosing
  // the nearest unmatched entry first. This prevents a single allowlist entry from
  // silently covering several nearby matches in a densely-annotated file.
  final consumed = <int>{};
  final unexpected = <_Match>[];
  for (final match in liveMatches) {
    int? bestIndex;
    int bestDelta = 1 << 30;
    for (var i = 0; i < allowlist.length; i++) {
      if (consumed.contains(i)) continue;
      final entry = allowlist[i];
      if (entry.path != match.path) continue;
      final delta = (entry.line - match.line).abs();
      if (delta <= 3 && delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }
    if (bestIndex == null) {
      unexpected.add(match);
    } else {
      consumed.add(bestIndex);
    }
  }

  final stale = <_AllowlistEntry>[
    for (var i = 0; i < allowlist.length; i++)
      if (!consumed.contains(i)) allowlist[i],
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

String _canonicalize(String path) {
  try {
    return File(path).absolute.uri.normalizePath().toFilePath();
  } catch (_) {
    return path;
  }
}

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

  factory _AllowlistEntry.parse(String line, String Function(String) canonicalize) {
    // Split from the right so colons inside the path (Windows drive letters) or
    // inside the reason text don't confuse the parser. Format is `path:line:reason`.
    final lastColon = line.lastIndexOf(':');
    if (lastColon <= 0) {
      throw FormatException('Invalid allowlist entry: $line');
    }
    final secondLastColon = line.lastIndexOf(':', lastColon - 1);
    if (secondLastColon <= 0) {
      throw FormatException('Invalid allowlist entry: $line');
    }
    final rawPath = line.substring(0, secondLastColon);
    final lineNumber = int.parse(line.substring(secondLastColon + 1, lastColon));
    final reason = line.substring(lastColon + 1);
    return _AllowlistEntry(canonicalize(rawPath), lineNumber, reason);
  }
}
