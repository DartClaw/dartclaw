import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show ActionNode, OutputFormat, WorkflowRun, WorkflowStep;
import 'package:dartclaw_security/dartclaw_security.dart'
    show EnvPolicy, SafeProcess, kDefaultSensitivePatterns;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'json_extraction.dart';
import 'shell_escape.dart';
import 'workflow_context.dart';
import 'workflow_runner_types.dart';
import 'workflow_template_engine.dart';

const _bashStdoutMaxBytes = 64 * 1024;
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

  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();

  late int exitCode;
  try {
    exitCode = await process.exitCode.timeout(Duration(seconds: timeoutSeconds));
  } on TimeoutException {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    final stderr = await stderrFuture;
    return bashFailure(step, 'timed out after ${timeoutSeconds}s', stderr: stderr);
  }

  final rawStdout = await stdoutFuture;
  final truncated = rawStdout.length > _bashStdoutMaxBytes;
  final stdout = truncated ? '${rawStdout.substring(0, _bashStdoutMaxBytes)}[truncated]' : rawStdout;
  final stderr = await stderrFuture;

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
      if (truncated) '${step.id}.stdoutTruncated': true,
    },
    tokenCount: 0,
    success: true,
  );
}

/// Resolves the working directory for a bash step.
String resolveBashWorkdir({
  required WorkflowStep step,
  required WorkflowContext context,
  required String dataDir,
  required WorkflowTemplateEngine templateEngine,
}) {
  if (step.workdir != null) {
    final resolved = templateEngine.resolve(step.workdir!, context).trim();
    if (resolved.isEmpty) {
      throw ArgumentError('workdir resolved to an empty path');
    }
    return resolved;
  }
  final workspaceRoot = p.join(dataDir, 'workspace');
  Directory(workspaceRoot).createSync(recursive: true);
  return workspaceRoot;
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
