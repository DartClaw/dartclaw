import 'dart:io';

final _pattern = RegExp(r'_workflow|workflowRunId|stepIndex');
final _forbiddenActiveWorkflowPath = RegExp(
  r'\b(?:WorkflowCliRunner|WorkflowCliProcessStarter|CliProcessSupervisor|CliProvider|ClaudeCliProvider|CodexCliProvider|ProcessRunner)\b'
  r'|\b(?:Process|SafeProcess)\.(?:run|runSync|start|startSync)\s*\('
  r'|(?:workflow_cli_runner|cli_process_supervisor|(?:claude_|codex_)?cli_provider)\.dart',
);
final _partDirective = RegExp(r"^\s*part\s+'([^']+)'\s*;", multiLine: true);

void main(List<String> args) {
  final sourcePath = _argValue(args, '--source');
  final allowlistPath = _argValue(args, '--allowlist');
  final workflowRunnerPath = _argValue(args, '--workflow-runner-source');
  final stepRunnerPath = _argValue(args, '--step-runner-source');
  if (sourcePath == null || allowlistPath == null || workflowRunnerPath == null || stepRunnerPath == null) {
    stderr.writeln(
      'Usage: dart run dev/tools/fitness/check_task_executor_workflow_refs.dart '
      '--source <path> --allowlist <path> '
      '--workflow-runner-source <path> --step-runner-source <path>',
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
  final activeWorkflowFiles = <File>[];
  for (final root in [File(workflowRunnerPath), File(stepRunnerPath)]) {
    activeWorkflowFiles.add(root);
    if (!root.existsSync()) continue;
    for (final part in _partDirective.allMatches(root.readAsStringSync())) {
      activeWorkflowFiles.add(File.fromUri(root.parent.uri.resolve(part.group(1)!)));
    }
  }
  for (final file in activeWorkflowFiles) {
    if (!file.existsSync()) {
      stderr.writeln('Active workflow source not found: ${file.path}');
      exitCode = 66;
      return;
    }
  }

  final normalizedSource = _canonicalize(sourceFile.path);
  final sourceLines = _foldDirectives(sourceFile.readAsLinesSync());
  final liveMatches = <_Match>[];
  for (final line in sourceLines) {
    if (_pattern.hasMatch(line.text)) {
      liveMatches.add(_Match(line.number, _stableIdentifier(line.text)));
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

  final forbiddenReachability = <({String path, int line, String token})>[];
  for (final file in activeWorkflowFiles) {
    final source = file.readAsStringSync();
    for (final match in _forbiddenActiveWorkflowPath.allMatches(source)) {
      forbiddenReachability.add((
        path: _canonicalize(file.path),
        line: '\n'.allMatches(source.substring(0, match.start)).length + 1,
        token: match.group(0)!,
      ));
    }
  }

  if (unexpected.isEmpty && stale.isEmpty && forbiddenReachability.isEmpty) {
    stdout.writeln(
      'Fitness function passed: task_executor workflow references match the allowlist '
      '(${liveMatches.length} matches), and the active step path has no legacy CLI or process-starter reachability.',
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
  if (forbiddenReachability.isNotEmpty) {
    stderr.writeln('Forbidden legacy CLI or process-starter reachability in the active workflow step path:');
    for (final match in forbiddenReachability) {
      stderr.writeln('  ${match.path}:${match.line}: ${match.token}');
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

/// Joins a formatter-wrapped `import`/`export` directive back into one logical
/// line so an allowlist identifier pins the shown symbols, not just the URI.
List<_SourceLine> _foldDirectives(List<String> lines) {
  final folded = <_SourceLine>[];
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
      folded.add(_SourceLine(i + 1, lines[i]));
      continue;
    }
    final buffer = StringBuffer(lines[i]);
    final start = i;
    while (!lines[i].trimRight().endsWith(';') && i + 1 < lines.length) {
      i++;
      buffer.write(' ');
      buffer.write(lines[i]);
    }
    folded.add(_SourceLine(start + 1, buffer.toString()));
  }
  return folded;
}

class _SourceLine {
  final int number;
  final String text;

  new(this.number, this.text);
}

class _Match {
  final int line;
  final String identifier;

  new(this.line, this.identifier);
}

class _AllowlistEntry {
  final String identifier;
  final String reason;

  new(this.identifier, this.reason);

  factory parse(String line) {
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
