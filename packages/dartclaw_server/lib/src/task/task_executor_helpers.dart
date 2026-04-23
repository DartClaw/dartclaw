part of 'task_executor.dart';

extension _TaskExecutorHelpers on TaskExecutor {
  Future<void> _runPoolTask(Task runningTask, TurnRunner runner, {required int runnerIndex}) async {
    try {
      await _executeWithRunner(runningTask, runner, runnerIndex: runnerIndex);
    } finally {
      _observer?.markIdle(runnerIndex);
      _pool.release(runner);
    }
  }

  Future<Task?> _checkout(Task queuedTask) async {
    try {
      return await _tasks.transition(queuedTask.id, TaskStatus.running, trigger: 'system');
    } on StateError {
      return null;
    }
  }

  Future<_QueuedTaskDisposition> _prepareQueuedTask(Task task) async {
    final projectService = _projectService;
    if (projectService == null) return _QueuedTaskDisposition.ready;

    final projectId = taskProjectId(task);
    if (projectId == null) return _QueuedTaskDisposition.ready;

    final project = await projectService.get(projectId);
    if (project == null) {
      await _failureHandler.markFailedOrRetry(task, errorSummary: 'Project "$projectId" not found', retryable: false);
      return _QueuedTaskDisposition.handled;
    }
    if (project.status == ProjectStatus.cloning) return _QueuedTaskDisposition.waiting;
    if (project.status == ProjectStatus.error) {
      final detail = project.errorMessage?.trim();
      final summary = (detail == null || detail.isEmpty)
          ? 'Project "${project.name}" failed to clone'
          : 'Project "${project.name}" failed to clone: $detail';
      await _failureHandler.markFailedOrRetry(task, errorSummary: summary, retryable: false);
      return _QueuedTaskDisposition.handled;
    }
    return _QueuedTaskDisposition.ready;
  }

  Future<void> _executeWithRunner(Task runningTask, TurnRunner runner, {required int runnerIndex}) {
    return _executeCore(
      runningTask,
      runnerIndex: runnerIndex,
      provider: runner.providerId,
      runnerProfileId: runner.profileId,
      reserveTurn:
          (
            sessionId, {
            String? directory,
            String? model,
            String? effort,
            BehaviorFileService? behaviorOverride,
            PromptScope? promptScope,
          }) => runner.reserveTurn(
            sessionId,
            agentName: 'task',
            directory: directory,
            model: model,
            effort: effort,
            behaviorOverride: behaviorOverride,
            promptScope: promptScope,
          ),
      executeTurn: runner.executeTurn,
      waitForOutcome: runner.waitForOutcome,
      setTaskToolFilter: runner.setTaskToolFilter,
      setTaskReadOnly: runner.setTaskReadOnly,
    );
  }

  Future<void> _execute(Task runningTask) {
    return _executeCore(
      runningTask,
      runnerIndex: 0,
      runnerProfileId: resolveProfile(runningTask.type),
      reserveTurn:
          (
            sessionId, {
            String? directory,
            String? model,
            String? effort,
            BehaviorFileService? behaviorOverride,
            PromptScope? promptScope,
          }) => _reserveSharedTurn(
            sessionId,
            directory: directory,
            model: model,
            effort: effort,
            behaviorOverride: behaviorOverride,
            promptScope: promptScope,
          ),
      executeTurn: _turns.executeTurn,
      waitForOutcome: _turns.waitForOutcome,
      setTaskToolFilter: _turns.setTaskToolFilter,
      setTaskReadOnly: _turns.setTaskReadOnly,
    );
  }

  Future<String> _reserveSharedTurn(
    String sessionId, {
    String? directory,
    String? model,
    String? effort,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
  }) async {
    while (true) {
      try {
        return await _turns.reserveTurn(
          sessionId,
          agentName: 'task',
          directory: directory,
          model: model,
          effort: effort,
          behaviorOverride: behaviorOverride,
          promptScope: promptScope,
        );
      } on BusyTurnException {
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  Future<String?> _composePendingMessage(Task task, String sessionId, {String? workingDirectory}) async {
    final goalContext = await _goalContextFor(task);
    final pushBackComment = TaskConfigView(task, log: TaskExecutor._log).pushBackComment;
    if (pushBackComment != null) {
      return _pushBackPrompt(pushBackComment, goalContext: goalContext, workingDirectory: workingDirectory);
    }

    return _initialPrompt(task, goalContext: goalContext, workingDirectory: workingDirectory);
  }

  String _initialPrompt(Task task, {String? goalContext, String? workingDirectory}) {
    final buffer = StringBuffer();
    if (task.retryCount > 0) {
      final lastError = TaskConfigView(task, log: TaskExecutor._log).lastError;
      buffer
        ..writeln('## Retry Context')
        ..writeln()
        ..writeln('Previous attempt failed: ${lastError ?? "unknown error"}')
        ..writeln('This is retry ${task.retryCount} of ${task.maxRetries}.')
        ..writeln('Approach the task differently — avoid the strategy that caused the previous failure.')
        ..writeln();
    }

    buffer
      ..writeln('## Task: ${task.title}')
      ..writeln()
      ..writeln(task.description.trim());

    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('### Working Directory')
        ..writeln('`$workingDirectory`')
        ..writeln()
        ..writeln('Use the reserved task worktree as the only workspace for this task.');
    }

    if (goalContext != null && goalContext.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(goalContext);
    }

    final acceptanceCriteria = task.acceptanceCriteria?.trim();
    if (acceptanceCriteria != null && acceptanceCriteria.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('### Acceptance Criteria')
        ..writeln(acceptanceCriteria);
    }

    return buffer.toString().trimRight();
  }

  Future<String?> _goalContextFor(Task task) async {
    final goalId = task.goalId;
    if (goalId == null || goalId.isEmpty) return null;
    return _goals?.resolveGoalContext(goalId);
  }

  String _pushBackPrompt(String comment, {String? goalContext, String? workingDirectory}) {
    final lines = <String>[
      '## Push-back Feedback',
      '',
      'The previous output was reviewed and pushed back with the following feedback:',
      '',
      comment,
    ];

    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) {
      lines
        ..add('')
        ..add('### Working Directory')
        ..add('`$workingDirectory`')
        ..add('')
        ..add('Continue using `$workingDirectory` as the only workspace for this task.');
    }

    if (goalContext != null && goalContext.isNotEmpty) {
      lines
        ..add('')
        ..add(goalContext);
    }

    lines
      ..add('')
      ..add('Please address the feedback and try again.');
    return lines.join('\n');
  }

  Map<String, dynamic>? _clearPushBackComment(Map<String, dynamic> configJson) {
    if (!configJson.containsKey('pushBackComment')) return null;
    final next = Map<String, dynamic>.from(configJson)..remove('pushBackComment');
    return next;
  }

  List<String>? _allowedTools(Task task) => TaskConfigView(task, log: TaskExecutor._log).allowedTools;

  bool _isReadOnlyTask(Task task) => TaskConfigView(task, log: TaskExecutor._log).isReadOnly;

  bool _isWorkflowOrchestrated(Task task) => TaskConfigView(task, log: TaskExecutor._log).isWorkflowOrchestrated;

  TaskStatus _resolvePostCompletionStatus(Task task) =>
      TaskConfigView(task, log: TaskExecutor._log).postCompletionStatus;

  bool _taskNeedsWorktree(Task task) => TaskConfigView(task, log: TaskExecutor._log).needsWorktree;

  String? _modelOverride(Task task) => TaskConfigView(task, log: TaskExecutor._log).model;

  String? _effortOverride(Task task) => TaskConfigView(task, log: TaskExecutor._log).effort;

  int? _tokenBudget(Task task) => TaskConfigView(task, log: TaskExecutor._log).tokenBudget;

  String? _taskBaseRef(Task task) => TaskConfigView(task, log: TaskExecutor._log).baseRef;

  Future<String?> _resolveEffectiveBaseRef(Task task, Project project, {String? explicitBaseRef}) async {
    if (explicitBaseRef != null && explicitBaseRef.isNotEmpty) return explicitBaseRef;
    if (project.id == '_local' && _isWorkflowOrchestrated(task)) {
      final head = await _worktreeBinder.currentSymbolicHead(project.localPath, noSystemConfig: true);
      if (head != null && head.isNotEmpty) return head;
    }
    return project.defaultBranch;
  }

  String? _freshnessRefFor(Project project, String? baseRef) {
    if (baseRef == null || baseRef.isEmpty) return null;
    if (project.remoteUrl.isNotEmpty && baseRef.startsWith('origin/')) {
      final trimmed = baseRef.substring('origin/'.length).trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return baseRef;
  }

  Future<String?> _worktreeBaseRefFor(Task task, Project project, String? baseRef) async {
    if (baseRef == null || baseRef.isEmpty) return null;
    if (_isWorkflowOrchestrated(task) ||
        project.remoteUrl.isEmpty ||
        baseRef.startsWith('origin/') ||
        baseRef.startsWith('refs/')) {
      return baseRef;
    }
    return 'origin/$baseRef';
  }

  bool _isWorkflowOwnedLocalRef(String? ref) => ref != null && ref.startsWith('dartclaw/workflow/');

  String? _readOnlyCheckDir(Task task, Project project) {
    final worktreePath = task.worktreeJson?['path'];
    if (worktreePath is String && worktreePath.trim().isNotEmpty) return worktreePath;
    return project.localPath;
  }

  Future<GitStatusSnapshot?> _captureReadOnlyProjectStatus(Task task, Project? project) async {
    if (!_isReadOnlyTask(task) || project == null) return null;
    final workingDirectory = _readOnlyCheckDir(task, project);
    if (workingDirectory == null || workingDirectory.isEmpty) return null;
    try {
      return await TaskReadOnlyGuard(worktreePath: workingDirectory, log: TaskExecutor._log).baseline();
    } catch (error) {
      TaskExecutor._log.fine(
        'Task ${task.id}: skipping read-only mutation baseline for "$workingDirectory" '
        'because git status threw: $error',
      );
      return null;
    }
  }

  Future<String?> _readOnlyMutationSummary(Task task, Project? project, GitStatusSnapshot? baseline) async {
    if (!_isReadOnlyTask(task) || project == null || baseline == null) return null;
    final workingDirectory = _readOnlyCheckDir(task, project);
    if (workingDirectory == null || workingDirectory.isEmpty) return null;
    return TaskReadOnlyGuard(worktreePath: workingDirectory, log: TaskExecutor._log).mutationSummary(baseline);
  }

  String _defaultTurnFailureSummary(TurnStatus status) =>
      status == TurnStatus.cancelled ? 'Turn cancelled' : 'Turn execution failed';

  Future<void> _persistTrace(
    TurnTraceService traceService, {
    required TurnOutcome outcome,
    required String taskId,
    required int runnerId,
    String? model,
    String? provider,
  }) async {
    try {
      final endedAt = outcome.completedAt;
      final startedAt = endedAt.subtract(outcome.turnDuration);
      await traceService.insert(
        TurnTrace(
          id: TaskExecutor._uuid.v4(),
          sessionId: outcome.sessionId,
          taskId: taskId,
          runnerId: runnerId,
          model: model,
          provider: provider,
          startedAt: startedAt,
          endedAt: endedAt,
          inputTokens: outcome.inputTokens,
          outputTokens: outcome.outputTokens,
          cacheReadTokens: outcome.cacheReadTokens,
          cacheWriteTokens: outcome.cacheWriteTokens,
          isError: outcome.status != TurnStatus.completed,
          errorType: outcome.status != TurnStatus.completed ? outcome.errorMessage : null,
          toolCalls: outcome.toolCalls,
        ),
      );
    } catch (error, stackTrace) {
      TaskExecutor._log.warning('Failed to persist turn trace for task $taskId', error, stackTrace);
    }
  }
}
