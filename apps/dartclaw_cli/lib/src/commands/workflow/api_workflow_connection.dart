import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, WorkflowDefinition;

import '../connected_command_support.dart';
import 'workflow_connection.dart';
import 'cli_progress_printer.dart';
import 'live_status_line.dart';
import 'workflow_progress_renderer.dart';
import 'connected_progress_decoder.dart';
import 'standalone_run_harness.dart' show standaloneWorkflowExitCode;

class ApiWorkflowConnection implements WorkflowConnection {
  final DartclawApiClient? _apiClient;
  new({DartclawApiClient? apiClient}) : _apiClient = apiClient;

  Future<void> _withClient(WorkflowConnectionContext context, Future<void> Function(DartclawApiClient) body) async {
    final client = resolveCliApiClient(
      globalResults: context.globalResults,
      config: context.config,
      apiClient: _apiClient,
    );
    await runCliConnected(client, body, stderrLine: context.stderrLine, exitFn: context.exitFn);
  }

  @override
  Future<void> status(WorkflowConnectionContext context, String runId, void Function(Map<String, dynamic>) onResult) =>
      _withClient(context, (client) async {
        onResult(await client.getObject('/api/workflows/runs/$runId'));
      });

  @override
  Future<void> definition(
    WorkflowConnectionContext context,
    String name, {
    required bool resolved,
    required String? stepId,
    required void Function(String) onResult,
  }) => _withClient(context, (client) async {
    onResult(
      await client.getText(
        '/api/workflows/definitions/$name',
        queryParameters: resolved ? {'resolve': 'true', if (stepId != null && stepId.isNotEmpty) 'step': stepId} : null,
      ),
    );
  });

  @override
  Future<void> runAction(
    WorkflowConnectionContext context,
    String runId,
    String pathSuffix,
    void Function(Map<String, dynamic>) onResult,
  ) => _withClient(context, (client) async {
    onResult(await client.postObject('/api/workflows/runs/$runId/$pathSuffix'));
  });

  @override
  Future<void> cancel(
    WorkflowConnectionContext context,
    String runId,
    String? feedback,
    void Function(Map<String, dynamic>) onResult,
  ) => _withClient(context, (client) async {
    await client.post('/api/workflows/runs/$runId/cancel', body: {'feedback': ?feedback});
    onResult(await client.getObject('/api/workflows/runs/$runId'));
  });

  @override
  Future<void> run(
    WorkflowConnectionContext context, {
    required String workflowName,
    required Map<String, String> variables,
    required String? projectId,
    required WorkflowApprovalPolicy? approvals,
    required bool allowDirtyLocalPath,
    required bool inline,
    required bool jsonOutput,
    required Stream<void> Function() interrupts,
  }) async {
    final client = resolveCliApiClient(
      globalResults: context.globalResults,
      config: context.config,
      apiClient: _apiClient,
    );
    try {
      await _runConnected(
        context,
        apiClient: client,
        workflowName: workflowName,
        variables: variables,
        projectId: projectId,
        approvals: approvals,
        allowDirtyLocalPath: allowDirtyLocalPath,
        inline: inline,
        jsonOutput: jsonOutput,
        interrupts: interrupts,
      );
    } on DartclawApiException catch (error) {
      context.stderrLine(_connectedErrorMessage(context, error));
      context.exitFn(connectedExitCode(error));
    }
  }

  Future<void> _runConnected(
    WorkflowConnectionContext context, {
    required Stream<void> Function() interrupts,
    required DartclawApiClient apiClient,
    required String workflowName,
    required Map<String, String> variables,
    required String? projectId,
    required WorkflowApprovalPolicy? approvals,
    required bool allowDirtyLocalPath,
    required bool inline,
    required bool jsonOutput,
  }) async {
    final started = await apiClient.postObject(
      '/api/workflows/run',
      body: {
        'definition': workflowName,
        'variables': variables,
        if (projectId != null && projectId.isNotEmpty) 'project': projectId,
        if (approvals != null) 'approvals': approvals.yamlValue,
        if (allowDirtyLocalPath) 'allowDirtyLocalPath': true,
        if (inline) 'inline': true,
      },
    );
    final run = WorkflowRun.fromJson(started);
    final definition = WorkflowDefinition.fromJson(Map<String, dynamic>.from(started['definitionJson'] as Map));
    final printer = CliProgressPrinter(
      commandPrefix: context.prefix,
      totalSteps: definition.steps.length,
      workflowName: definition.name,
      writeLine: context.writeLine,
      liveStatusLine: LiveStatusLine.forStdout(jsonOutput: jsonOutput),
    );
    // The connected lane is a thin HTTP/SSE client (ADR-030): it supplies the
    // renderer a definition-backed step-context resolver and no JSON sink —
    // its `--json` stream is the server's frames, echoed in the loop below.
    final renderer = WorkflowProgressRenderer(
      definition: definition,
      printer: printer,
      jsonOutput: jsonOutput,
      resolveStepContext: (update) {
        final stepIndex = update.stepIndex;
        if (stepIndex == null || stepIndex >= definition.steps.length) return null;
        final step = definition.steps[stepIndex];
        return TaskStepContext(
          stepIndex: stepIndex,
          stepId: step.id,
          title: step.name,
          provider: step.provider,
          displayScope: update.displayScope,
        );
      },
    );

    if (jsonOutput) {
      context.writeLine(jsonEncode({'type': 'run_started', 'run': started}));
    } else {
      printer.workflowStarted();
    }

    final completer = Completer<int>();
    var lastStatus = run.status;
    var lastError = run.errorMessage;
    var cancelRequested = false;

    final interruptSub = interrupts().listen((_) async {
      if (cancelRequested) {
        context.exitFn(1);
      }
      cancelRequested = true;
      if (jsonOutput) {
        context.writeLine(jsonEncode({'type': 'interrupt_received', 'runId': run.id}));
      } else {
        printer.workflowCancelling();
      }
      try {
        await apiClient.post('/api/workflows/runs/${run.id}/cancel');
      } on DartclawApiException catch (error) {
        context.stderrLine(error.message);
      }
    });

    try {
      await for (final event in apiClient.streamEvents(
        '/api/workflows/runs/${run.id}/events',
        onDisconnect: (attempt) async {
          final refreshed = await apiClient.getObject('/api/workflows/runs/${run.id}');
          final refreshedRun = WorkflowRun.fromJson(refreshed);
          lastStatus = refreshedRun.status;
          lastError = refreshedRun.errorMessage;
          if (lastStatus.terminal ||
              lastStatus == WorkflowRunStatus.paused ||
              lastStatus == WorkflowRunStatus.awaitingApproval) {
            if (!completer.isCompleted) {
              completer.complete(standaloneWorkflowExitCode(lastStatus));
            }
            return false;
          }
          if (jsonOutput) {
            context.writeLine(
              jsonEncode({
                'type': 'stream_reconnecting',
                'runId': run.id,
                'attempt': attempt,
                'status': lastStatus.name,
              }),
            );
          } else {
            context.stderrLine(
              'Workflow event stream disconnected. Reconnecting (attempt $attempt/3) after re-fetching status...',
            );
          }
          return true;
        },
      )) {
        if (jsonOutput) {
          context.writeLine(jsonEncode(event));
        }
        if (event['type'] == 'workflow_status_changed') {
          final newStatusName = event['newStatus']?.toString();
          final newStatus = newStatusName == null ? null : WorkflowRunStatus.values.asNameMap()[newStatusName];
          if (newStatus == null) {
            continue;
          }
          lastStatus = newStatus;
          lastError = event['errorMessage']?.toString();
          if (!lastStatus.terminal &&
              lastStatus != WorkflowRunStatus.paused &&
              lastStatus != WorkflowRunStatus.awaitingApproval) {
            continue;
          }
          if (!jsonOutput) {
            switch (lastStatus) {
              case WorkflowRunStatus.completed:
                printer.workflowCompleted(definition.steps.length, event['totalTokens'] as int? ?? run.totalTokens);
              case WorkflowRunStatus.failed:
                printer.workflowFailed((event['currentStepIndex'] as int? ?? 0), lastError);
              case WorkflowRunStatus.cancelled:
                printer.workflowFailed((event['currentStepIndex'] as int? ?? 0), lastError ?? 'Cancelled');
              case WorkflowRunStatus.paused:
                printer.workflowPaused((event['currentStepIndex'] as int? ?? 0), lastError);
              case WorkflowRunStatus.awaitingApproval:
                printer.workflowPaused((event['currentStepIndex'] as int? ?? 0), lastError);
              case WorkflowRunStatus.pending || WorkflowRunStatus.running:
                break;
            }
          }
          if (!completer.isCompleted) {
            completer.complete(standaloneWorkflowExitCode(lastStatus));
          }
          break;
        }
        await renderConnectedWorkflowFrame(event, renderer);
      }
    } on DartclawApiException catch (error) {
      final refreshed = await apiClient.getObject('/api/workflows/runs/${run.id}');
      lastStatus = WorkflowRun.fromJson(refreshed).status;
      lastError = WorkflowRun.fromJson(refreshed).errorMessage;
      if (lastStatus.terminal ||
          lastStatus == WorkflowRunStatus.paused ||
          lastStatus == WorkflowRunStatus.awaitingApproval) {
        if (!completer.isCompleted) {
          completer.complete(standaloneWorkflowExitCode(lastStatus));
        }
      } else {
        throw DartclawApiException(
          '${error.message} Use `${context.prefix} status ${run.id}` to inspect the run.',
          code: error.code,
          statusCode: error.statusCode,
          details: error.details,
        );
      }
    } finally {
      printer.disposeLive();
      await interruptSub.cancel();
    }

    final exitCode = completer.isCompleted ? await completer.future : standaloneWorkflowExitCode(lastStatus);
    if (!jsonOutput && lastStatus == WorkflowRunStatus.cancelled && lastError == null && cancelRequested) {
      context.writeLine('[workflow] Cancelled: ${run.id}');
    }
    context.exitFn(exitCode);
  }

  String _connectedErrorMessage(WorkflowConnectionContext context, DartclawApiException error) {
    if (error.code == 'CONNECTION_REFUSED') {
      return '${error.message} Or use `${context.prefix} run --standalone <name>` if you need in-process execution.';
    }
    return error.message;
  }
}
