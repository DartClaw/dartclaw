import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:dartclaw_models/dartclaw_models.dart' show ActionNode, OutputFormat, WorkflowRun, WorkflowStep;
import 'package:dartclaw_security/dartclaw_security.dart' show EnvPolicy, SafeProcess, kDefaultSensitivePatterns;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'json_extraction.dart';
import 'shell_escape.dart';
import 'workflow_context.dart';
import 'workflow_runner_types.dart';
import 'workflow_template_engine.dart';

const _bashStdoutMaxBytes = 64 * 1024;
const _bashStderrMaxBytes = 64 * 1024;
final _log = Logger('BashStepRunner');

/// Runs a normalized bash action node.
Future<StepOutcome> bashStepRun(ActionNode node, StepExecutionContext ctx) async {
  final definition = ctx.definition;
  final run = ctx.run;
  final context = ctx.workflowContext;
  if (definition == null || run == null || context == null) {
    throw StateError('bashStepRun requires run, definition, and workflowContext on StepExecutionContext.');
  }
  final step = definition.steps.firstWhere((candidate) => candidate.id == node.stepId);
  return executeBashStep(
    run: run,
    step: step,
    context: context,
    dataDir: ctx.dataDir ?? Directory.current.path,
    templateEngine: ctx.templateEngine ?? WorkflowTemplateEngine(),
    hostEnvironment: ctx.hostEnvironment,
    envAllowlist: ctx.bashStepEnvAllowlist,
    extraStripPatterns: ctx.bashStepExtraStripPatterns,
  );
}

/// Executes a `type: bash` step on the host via [SafeProcess.start].
Future<StepOutcome> executeBashStep({
  required WorkflowRun run,
  required WorkflowStep step,
  required WorkflowContext context,
  required String dataDir,
  required WorkflowTemplateEngine templateEngine,
  Map<String, String>? hostEnvironment,
  List<String> envAllowlist = BashStepPolicy.defaultEnvAllowlist,
  List<String> extraStripPatterns = const <String>[],
}) async {
  assert(step.type == 'bash', 'bash runner received non-bash step ${step.id}');
  final String workDir;
  try {
    workDir = resolveBashWorkdir(step: step, context: context, dataDir: dataDir, templateEngine: templateEngine);
  } catch (e) {
    return bashFailure(step, 'workdir resolution failed: $e');
  }

  if (!Directory(workDir).existsSync()) {
    return bashFailure(step, 'workdir does not exist: $workDir');
  }

  final rawCommand = step.prompts?.firstOrNull ?? '';
  final String resolvedCommand;
  try {
    validateBashCommandTemplate(rawCommand);
    resolvedCommand = resolveBashCommand(rawCommand, context);
  } catch (e) {
    return bashFailure(step, 'command substitution failed: $e');
  }

  final timeoutSeconds = step.timeoutSeconds ?? 60;
  late Process process;
  try {
    process = await SafeProcess.start(
      '/bin/sh',
      ['-c', resolvedCommand],
      env: EnvPolicy.sanitize(
        allowlist: envAllowlist,
        sensitivePatterns: [...kDefaultSensitivePatterns, ...extraStripPatterns],
      ),
      baseEnvironment: hostEnvironment,
      workingDirectory: workDir,
      runInShell: false,
    );
  } catch (e) {
    return bashFailure(step, 'process execution failed: $e');
  }

  final stdoutFuture = _collectBounded(process.stdout, _bashStdoutMaxBytes);
  final stderrFuture = _collectBounded(process.stderr, _bashStderrMaxBytes);

  late int exitCode;
  try {
    exitCode = await process.exitCode.timeout(Duration(seconds: timeoutSeconds));
  } on TimeoutException {
    await _terminateProcessTree(process);
    final stderr = await _waitForBoundedDrain(stderrFuture);
    return bashFailure(step, 'timed out after ${timeoutSeconds}s', stderr: stderr.text);
  }

  final stdoutResult = await stdoutFuture;
  final stderrResult = await stderrFuture;
  final stdout = stdoutResult.truncated ? '${stdoutResult.text}[truncated]' : stdoutResult.text;
  final stderr = stderrResult.truncated ? '${stderrResult.text}[truncated]' : stderrResult.text;

  if (exitCode != 0) {
    _log.warning(
      "Workflow '${run.id}': bash step '${step.id}' exited $exitCode"
      "${stderr.isNotEmpty ? ': ${stderr.trim()}' : ''}",
    );
    return bashFailure(step, 'exited with code $exitCode', stderr: stderr);
  }

  final Map<String, dynamic> outputs;
  try {
    outputs = extractBashOutputs(step, stdout);
  } on FormatException catch (e) {
    return bashFailure(step, e.message, stderr: stderr);
  }

  return StepOutcome(
    step: step,
    outputs: {
      ...outputs,
      '${step.id}.status': 'success',
      '${step.id}.exitCode': exitCode,
      '${step.id}.tokenCount': 0,
      '${step.id}.workdir': workDir,
      if (stderr.isNotEmpty) '${step.id}.stderr': stderr,
      if (stdoutResult.truncated) '${step.id}.stdoutTruncated': true,
      if (stderrResult.truncated) '${step.id}.stderrTruncated': true,
    },
    tokenCount: 0,
    success: true,
  );
}

Future<void> _terminateProcessTree(Process process) async {
  await _killProcessTree(process.pid, ProcessSignal.sigterm);
  process.kill();
  try {
    await process.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    await _killProcessTree(process.pid, ProcessSignal.sigkill);
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
  }
}

Future<void> _killProcessTree(int rootPid, ProcessSignal signal) async {
  final pids = await _descendantPids(rootPid);
  for (final pid in pids.reversed) {
    Process.killPid(pid, signal);
  }
}

Future<List<int>> _descendantPids(int rootPid) async {
  if (!Platform.isMacOS && !Platform.isLinux) return const [];
  final result = <int>[];
  var frontier = <int>[rootPid];
  while (frontier.isNotEmpty) {
    final next = <int>[];
    for (final pid in frontier) {
      final children = await _childPids(pid);
      for (final child in children) {
        if (!result.contains(child)) {
          result.add(child);
          next.add(child);
        }
      }
    }
    frontier = next;
  }
  return result;
}

Future<List<int>> _childPids(int pid) async {
  try {
    final result = await Process.run('pgrep', ['-P', '$pid']).timeout(const Duration(seconds: 1));
    if (result.exitCode != 0) return const [];
    return LineSplitter.split(
      result.stdout as String,
    ).map((line) => int.tryParse(line.trim())).whereType<int>().toList(growable: false);
  } on Object {
    return const [];
  }
}

Future<_BoundedOutput> _waitForBoundedDrain(Future<_BoundedOutput> future) {
  return future.timeout(const Duration(seconds: 2), onTimeout: () => const _BoundedOutput('', truncated: true));
}

/// Resolves the working directory for a bash step.
String resolveBashWorkdir({
  required WorkflowStep step,
  required WorkflowContext context,
  required String dataDir,
  required WorkflowTemplateEngine templateEngine,
}) {
  if (step.workdir != null) {
    if (step.workdir!.contains(RegExp(r'\{\{\s*context\.'))) {
      throw ArgumentError('workdir must not reference context values');
    }
    final resolved = templateEngine.resolve(step.workdir!, context).trim();
    if (resolved.isEmpty) {
      throw ArgumentError('workdir resolved to an empty path');
    }
    return _containedWorkdir(resolved, dataDir: dataDir);
  }
  final workspaceRoot = p.join(dataDir, 'workspace');
  Directory(workspaceRoot).createSync(recursive: true);
  return p.normalize(p.absolute(workspaceRoot));
}

/// Resolves template references in a shell command.
///
/// Both `{{context.key}}` and `{{VAR}}` substitutions are shell-escaped via
/// [shellEscape] — callers must not double-escape.
String resolveBashCommand(String command, WorkflowContext context) {
  return command.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (match) {
    final ref = match.group(1)!.trim();
    if (ref.startsWith('context.')) {
      final key = ref.substring('context.'.length);
      final value = context[key];
      if (value == null) {
        _log.warning(
          'Bash command template reference {{$ref}} resolved to empty string '
          '(key "$key" not in context)',
        );
        return shellEscape('');
      }
      return shellEscape(value.toString());
    }
    final value = context.variable(ref);
    if (value == null) {
      throw ArgumentError('Bash command references undefined variable: {{$ref}}');
    }
    return shellEscape(value);
  });
}

/// Heuristically rejects the most common shell-re-parsing patterns that
/// embed `{{context.*}}` substitutions. The patterns covered are `eval`,
/// `| sh|bash`, `sh -c {{...}}`/`bash -c {{...}}` immediately followed by a
/// substitution, command substitution `$(...)`, and backticks. The matcher
/// is intentionally narrow — it does not catch every quoting/wrapping shape
/// (e.g. `bash -c "echo {{context.x}}"`, `xargs -I {}`, parameter
/// expansion). The primary safety guarantee is `shellEscape` in
/// [resolveBashCommand], which always emits single-quoted output; this
/// validator is defense-in-depth on top of that escaping.
void validateBashCommandTemplate(String command) {
  if (!command.contains(RegExp(r'\{\{\s*context\.'))) return;
  final riskyPatterns = <RegExp>[
    RegExp(r'(^|[;&|]\s*)\s*eval\b'),
    RegExp(r'\|\s*(?:/usr/bin/env\s+)?(?:/bin/)?(?:sh|bash)\b'),
    RegExp(r'\b(?:sh|bash)\s+-c\s+\{\{\s*context\.'),
    RegExp(r'`[^`]*\{\{\s*context\.'),
    RegExp(r'\$\([^)]*\{\{\s*context\.'),
  ];
  for (final pattern in riskyPatterns) {
    if (pattern.hasMatch(command)) {
      throw ArgumentError(
        'Bash command uses {{context.*}} inside a shell re-parsing construct. '
        'Pass context values as ordinary command arguments instead.',
      );
    }
  }
}

String _containedWorkdir(String resolved, {required String dataDir}) {
  final dataDirRoot = p.normalize(p.absolute(dataDir));
  final workspaceRoot = p.join(dataDirRoot, 'workspace');
  final candidate = p.isAbsolute(resolved)
      ? p.normalize(p.absolute(resolved))
      : p.normalize(p.join(workspaceRoot, resolved));
  if (candidate != dataDirRoot && !p.isWithin(dataDirRoot, candidate)) {
    throw ArgumentError('workdir escapes dataDir: $resolved');
  }

  // Materialize the workdir up front so the realpath check has something to
  // resolve. Skipping the check when the dir is missing leaves a TOCTOU
  // window: a concurrent step (or the bash command itself via `mkdir -p`)
  // could plant a symlink at `candidate` between validation and Process.start.
  final dir = Directory(candidate);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final rootReal = Directory(dataDirRoot).resolveSymbolicLinksSync();
  final candidateReal = Directory(candidate).resolveSymbolicLinksSync();
  if (candidateReal != rootReal && !p.isWithin(rootReal, candidateReal)) {
    throw ArgumentError('workdir resolves outside dataDir: $resolved');
  }
  return candidate;
}

Future<_BoundedOutput> _collectBounded(Stream<List<int>> stream, int maxBytes) async {
  final builder = BytesBuilder(copy: false);
  var storedBytes = 0;
  var truncated = false;
  await for (final chunk in stream) {
    final remaining = maxBytes - storedBytes;
    if (remaining > 0) {
      final take = min(remaining, chunk.length);
      builder.add(chunk.sublist(0, take));
      storedBytes += take;
    }
    if (chunk.length > remaining) {
      truncated = true;
    }
  }
  return _BoundedOutput(utf8.decode(builder.takeBytes(), allowMalformed: true), truncated: truncated);
}

final class _BoundedOutput {
  final String text;
  final bool truncated;

  const _BoundedOutput(this.text, {required this.truncated});
}

/// Extracts declared context outputs from bash stdout.
Map<String, dynamic> extractBashOutputs(WorkflowStep step, String stdout) {
  if (step.outputKeys.isEmpty) return {};

  final outputs = <String, dynamic>{};
  for (final outputKey in step.outputKeys) {
    final config = step.outputs?[outputKey];
    final format = config?.format ?? OutputFormat.text;

    switch (format) {
      case OutputFormat.json:
        if (stdout.trim().isEmpty) {
          throw FormatException('Bash step "${step.id}": empty stdout for json extraction of "$outputKey"');
        } else {
          try {
            outputs[outputKey] = extractJson(stdout);
          } on FormatException catch (e) {
            throw FormatException('Bash step "${step.id}": JSON extraction failed for "$outputKey": $e');
          }
        }
      case OutputFormat.lines:
        outputs[outputKey] = extractLines(stdout);
      case OutputFormat.text:
      case OutputFormat.path:
        outputs[outputKey] = stdout;
    }
  }
  return outputs;
}

/// Returns a failed [StepOutcome] for a bash step.
StepOutcome bashFailure(WorkflowStep step, String reason, {String? stderr}) {
  _log.info("Bash step '${step.id}' failed: $reason");
  return StepOutcome(
    step: step,
    outputs: {
      '${step.id}.status': 'failed',
      '${step.id}.exitCode': -1,
      '${step.id}.tokenCount': 0,
      '${step.id}.error': reason,
      if (stderr != null && stderr.isNotEmpty) '${step.id}.stderr': stderr,
    },
    tokenCount: 0,
    success: false,
    error: reason,
  );
}
