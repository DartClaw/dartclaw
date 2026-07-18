import 'dart:async' show Completer, StreamSubscription, TimeoutException;
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:dartclaw_config/dartclaw_config.dart'
    show BashShellPolicy, PlatformCapabilities, UnsupportedCapabilityError;
import 'package:dartclaw_core/dartclaw_core.dart' show killWithEscalation;
import 'workflow_definition.dart' show ActionNode, OutputFormat, WorkflowStep, WorkflowTaskType;
import 'workflow_run.dart' show WorkflowRun;
import 'package:dartclaw_security/dartclaw_security.dart' show EnvPolicy, SafeProcess, defaultSensitivePatterns;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'bash_process_owner.dart';
import 'json_extraction.dart';
import 'workflow_context.dart';
import 'workflow_runner_types.dart';
import 'workflow_template_engine.dart';

part 'bash_output_collector.dart';
part 'bash_process_tree_runner.dart';

const _bashStdoutMaxBytes = 64 * 1024;
const _bashStderrMaxBytes = 64 * 1024;
final _log = Logger('BashStepRunner');

typedef BashShellInvocation = ({String executable, List<String> arguments});

Future<ExecutableLookupResult> _resolveExecutableLookup(String executable, PlatformCapabilities capabilities) async {
  final matches = <String>[];
  for (final candidate in capabilities.executableSearchCandidates(executable)) {
    if (await File(candidate).exists()) matches.add(candidate);
  }
  return (exitCode: matches.isEmpty ? 1 : 0, stdout: matches.join('\n'));
}

Future<BashShellInvocation> selectBashShell({
  required PlatformCapabilities capabilities,
  required String command,
  ExecutableLookupExecutor? executableLookup,
}) async {
  if (capabilities.bashShellPolicy == BashShellPolicy.systemSh) {
    return (executable: '/bin/sh', arguments: ['-c', command]);
  }

  final lookup = executableLookup ?? (executable, arguments) => _resolveExecutableLookup(executable, capabilities);
  final ExecutableLookupResult lookupResult;
  try {
    lookupResult = await lookup('bash', const []);
  } on ProcessException {
    throw _missingGitBashError();
  }
  final resolvedExecutable = LineSplitter.split(
    lookupResult.stdout,
  ).map((line) => line.trim()).where(_isGitForWindowsBash).firstOrNull;
  if (lookupResult.exitCode != 0 || resolvedExecutable == null) {
    throw _missingGitBashError();
  }
  return (executable: resolvedExecutable, arguments: ['-c', command]);
}

bool _isGitForWindowsBash(String candidate) {
  final normalized = candidate.replaceAll('\\', '/').toLowerCase();
  return normalized.endsWith('/bin/bash.exe') || normalized.endsWith('/usr/bin/bash.exe');
}

UnsupportedCapabilityError _missingGitBashError() {
  return UnsupportedCapabilityError(
    capability: 'bash shell',
    attemptedContext: 'Windows PATH search for bash.exe',
    remediation:
        'bash steps require Git Bash on Windows; install Git Bash, use a POSIX host or WSL, '
        'or wait for Workflow DSL v2 script support.',
  );
}

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
    capabilities: ctx.platformCapabilities,
    executableLookup: ctx.executableLookupExecutor,
    processOwner: ctx.bashProcessOwner,
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
  PlatformCapabilities? capabilities,
  ExecutableLookupExecutor? executableLookup,
  BashProcessOwner? processOwner,
}) async {
  assert(step.taskType == WorkflowTaskType.bash, 'bash runner received non-bash step ${step.id}');
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
    resolvedCommand = resolveBashCommand(rawCommand, context, templateEngine: templateEngine);
  } catch (e) {
    return bashFailure(step, 'command substitution failed: $e');
  }

  final timeoutSeconds = step.timeoutSeconds ?? 60;
  final platformCapabilities = capabilities ?? PlatformCapabilities();
  final owner = processOwner ?? sharedBashProcessOwner;
  await retryOwnedBashProcesses(owner, platformCapabilities);
  if (owner.cleanupPendingProcesses.isNotEmpty) {
    return bashFailure(step, 'prior Bash process-tree cleanup remains unconfirmed');
  }
  final BashShellInvocation shell;
  try {
    // Keeping the shell alive through its jobs preserves a safe process-tree root for deadline cleanup.
    final ownedCommand =
        r"trap '__dartclaw_step_exit_code=$?; trap - 0; wait; exit $__dartclaw_step_exit_code' 0"
        '\n$resolvedCommand';
    shell = await selectBashShell(
      capabilities: platformCapabilities,
      command: ownedCommand,
      executableLookup: executableLookup,
    );
  } on UnsupportedCapabilityError catch (e) {
    return bashFailure(step, e.toString());
  }
  late Process process;
  try {
    process = await SafeProcess.start(
      shell.executable,
      shell.arguments,
      env: EnvPolicy.sanitize(
        allowlist: envAllowlist,
        sensitivePatterns: [...defaultSensitivePatterns, ...extraStripPatterns],
      ),
      baseEnvironment: hostEnvironment,
      workingDirectory: workDir,
      runInShell: false,
    );
  } catch (e) {
    return bashFailure(step, 'process execution failed: $e');
  }
  owner.track(process);
  final stdoutCollector = _BoundedOutputCollector(process.stdout, _bashStdoutMaxBytes);
  final stderrCollector = _BoundedOutputCollector(process.stderr, _bashStderrMaxBytes);
  final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
  await _captureOwnedRootIdentity(owner, process, platformCapabilities);
  final descendantTracking = trackOwnedBashDescendants(owner, process, platformCapabilities);

  late int exitCode;
  late List<_BoundedOutput> outputResults;
  var rootExitObserved = false;
  try {
    exitCode = await process.exitCode.timeout(_remainingUntil(deadline));
    rootExitObserved = true;
    outputResults = await Future.wait([stdoutCollector.done, stderrCollector.done]).timeout(_remainingUntil(deadline));
  } on TimeoutException {
    owner.markCleanupPending(process);
    final exitConfirmed = await cleanupTimedOutBashProcess(
      owner,
      process,
      platformCapabilities,
      descendantTracking: descendantTracking,
      rootExitAlreadyObserved: rootExitObserved,
      confirmDescendantOutputsClosed: () async {
        try {
          await Future.wait([stdoutCollector.done, stderrCollector.done]).timeout(const Duration(milliseconds: 100));
          return true;
        } on Object {
          return false;
        }
      },
    );
    if (exitConfirmed) owner.confirmExit(process);
    final cancelledOutputs = await Future.wait([stdoutCollector.cancel(), stderrCollector.cancel()]);
    final stderr = cancelledOutputs[1];
    return bashFailure(step, 'timed out after ${timeoutSeconds}s', stderr: stderr.text);
  }
  await descendantTracking;
  if (owner.unidentifiedDescendantCleanup(process)) {
    owner.markCleanupPending(process);
    return bashFailure(step, 'process-tree inspection failed; cleanup remains unconfirmed');
  }
  final descendantIdentities = owner.descendantIdentitiesOf(process);
  if (descendantIdentities.isNotEmpty) {
    owner.markCleanupPending(process);
    final cleanupConfirmed = await owner.runCleanupAttempt(
      process,
      () => terminateBashProcessTree(
        process,
        platformCapabilities,
        rootProcessIdentity: owner.rootIdentityOf(process),
        knownDescendantIdentities: descendantIdentities,
        onOwnedDescendantsChanged: (identities) => owner.replaceDescendants(process, identities),
        rootExitAlreadyObserved: true,
      ),
    );
    if (!cleanupConfirmed) return bashFailure(step, 'process-tree cleanup remains unconfirmed');
  }
  owner.confirmExit(process);

  final stdoutResult = outputResults[0];
  final stderrResult = outputResults[1];
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
/// `{{context.key}}`, `{{workflow.key}}`, and `{{VAR}}` substitutions are
/// shell-escaped through the template engine's [EscapeMode.shell] (the single
/// escaping implementation) — callers must not double-escape.
///
/// Resolves against the no-map engine path, so `{{map.*}}` references are not
/// supported in bash commands and resolve as undefined variables.
String resolveBashCommand(String command, WorkflowContext context, {WorkflowTemplateEngine? templateEngine}) {
  return (templateEngine ?? WorkflowTemplateEngine()).resolve(command, context, escape: EscapeMode.shell);
}

/// Rejects template substitutions where caller-owned quoting or a nested
/// shell would reinterpret the shell-escaped value.
void validateBashCommandTemplate(String command) {
  final substitutions = RegExp(r'\{\{[^{}]+\}\}').allMatches(command).toList();
  if (substitutions.isEmpty) return;
  if (_hasQuotedSubstitution(command, substitutions)) {
    _throwUnsafeBashInterpolation();
  }
  if (_hasShellReparse(command)) _throwUnsafeBashInterpolation();
}

bool _hasShellReparse(String command) {
  final normalized = command.replaceAll(RegExp(r'''["'\\]'''), '');
  final riskyPatterns = <RegExp>[
    RegExp(r'\beval\b'),
    RegExp(r'''(^|[/\s;&|(<])(?:sh|bash|dash|zsh|ksh|ash|fish)(?:\.exe)?(?=$|["'\s;&|)>])'''),
    RegExp(r'<<-?(?!<)'),
    RegExp(r'`[^`]*\{\{'),
    RegExp(r'\$\([^)]*\{\{'),
  ];
  return riskyPatterns.any((pattern) => pattern.hasMatch(normalized));
}

bool _hasQuotedSubstitution(String command, List<RegExpMatch> substitutions) =>
    substitutions.any((substitution) => _isInsideShellQuote(command, substitution.start));

bool _isInsideShellQuote(String command, int end) {
  var quote = 0;
  for (var index = 0; index < end; index++) {
    final codeUnit = command.codeUnitAt(index);
    if (quote == 39) {
      if (codeUnit == 39) quote = 0;
      continue;
    }
    if (codeUnit == 92) {
      if (quote == 0 || (quote == 34 && index + 1 < end && _isEscapedInDoubleQuotes(command.codeUnitAt(index + 1)))) {
        index++;
      }
      continue;
    }
    if (codeUnit == 34) {
      quote = quote == 34 ? 0 : 34;
    } else if (quote == 0 && codeUnit == 39) {
      quote = 39;
    }
  }
  return quote != 0;
}

bool _isEscapedInDoubleQuotes(int codeUnit) =>
    codeUnit == 36 || codeUnit == 96 || codeUnit == 34 || codeUnit == 92 || codeUnit == 10;

Never _throwUnsafeBashInterpolation() {
  throw ArgumentError(
    'Bash command uses a template substitution inside caller-owned shell quoting or a shell re-parsing construct. '
    'Pass substituted values as unquoted ordinary command arguments instead.',
  );
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

Duration _remainingUntil(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  return remaining.isNegative ? Duration.zero : remaining;
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
