@Tags(['component'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities, UnsupportedCapabilityError;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnErrorPolicy,
        OutputConfig,
        OutputFormat,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/bash_step_runner.dart';
import 'package:dartclaw_workflow/src/workflow/bash_process_owner.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  group('bash_step_runner unit', () {
    group('selectBashShell', () {
      test('selects /bin/sh on POSIX without executable lookup', () async {
        var lookupCalled = false;

        final invocation = await selectBashShell(
          capabilities: PlatformCapabilities(operatingSystem: 'linux'),
          command: 'echo ok',
          executableLookup: (executable, arguments) async {
            lookupCalled = true;
            return (exitCode: 0, stdout: '/unexpected');
          },
        );

        expect(invocation.executable, '/bin/sh');
        expect(invocation.arguments, ['-c', 'echo ok']);
        expect(lookupCalled, isFalse);
      });

      test('selects resolved Git Bash on Windows', () async {
        final lookupCalls = <(String, List<String>)>[];

        final invocation = await selectBashShell(
          capabilities: PlatformCapabilities(operatingSystem: 'windows'),
          command: 'echo ok',
          executableLookup: (executable, arguments) async {
            lookupCalls.add((executable, arguments));
            return (exitCode: 0, stdout: 'C:\\Program Files\\Git\\bin\\bash.exe\r\n');
          },
        );

        expect(lookupCalls, hasLength(1));
        expect(lookupCalls.single.$1, 'bash');
        expect(lookupCalls.single.$2, isEmpty);
        expect(invocation.executable, r'C:\Program Files\Git\bin\bash.exe');
        expect(invocation.arguments, ['-c', 'echo ok']);
      });

      test('accepts a custom Git Bash installation root', () async {
        final invocation = await selectBashShell(
          capabilities: PlatformCapabilities(operatingSystem: 'windows'),
          command: 'echo ok',
          executableLookup: (executable, arguments) async =>
              (exitCode: 0, stdout: 'C:\\Tools\\Acme\\bin\\bash.exe\r\n'),
        );

        expect(invocation.executable, r'C:\Tools\Acme\bin\bash.exe');
      });

      test('skips non-Git bash candidates returned first', () async {
        final invocation = await selectBashShell(
          capabilities: PlatformCapabilities(operatingSystem: 'windows'),
          command: 'echo ok',
          executableLookup: (executable, arguments) async =>
              (exitCode: 0, stdout: 'C:\\Windows\\System32\\bash.exe\r\nC:\\Tools\\PortableGit\\bin\\bash.exe\r\n'),
        );

        expect(invocation.executable, r'C:\Tools\PortableGit\bin\bash.exe');
      });

      test('throws structured unsupported-capability error when Git Bash is missing', () async {
        final future = selectBashShell(
          capabilities: PlatformCapabilities(operatingSystem: 'windows'),
          command: 'echo ok',
          executableLookup: (executable, arguments) async => (exitCode: 1, stdout: ''),
        );

        await expectLater(
          future,
          throwsA(
            isA<UnsupportedCapabilityError>()
                .having((error) => error.capability, 'capability', contains('bash'))
                .having((error) => error.toString(), 'message', contains('bash steps require Git Bash on Windows'))
                .having((error) => error.remediation, 'remediation', contains('WSL')),
          ),
        );
      });

      test('rejects a non-Git bash candidate', () async {
        final future = selectBashShell(
          capabilities: PlatformCapabilities(operatingSystem: 'windows'),
          command: 'echo ok',
          executableLookup: (executable, arguments) async =>
              (exitCode: 0, stdout: 'C:\\Windows\\System32\\bash.exe\r\n'),
        );

        await expectLater(future, throwsA(isA<UnsupportedCapabilityError>()));
      });

      test('Windows timeout termination hard-kills the full process tree without POSIX signals', () async {
        final process = FakeProcess();
        final terminatedPids = <int>[];

        await terminateBashProcessTree(
          process,
          PlatformCapabilities(operatingSystem: 'windows'),
          rootProcessIdentity: null,
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (pid) async {
            terminatedPids.add(pid);
            process.exit(1);
            return ProcessResult(0, 0, '', '');
          },
        );

        expect(terminatedPids, [process.pid]);
        expect(process.killSignals, isEmpty);
      });

      test('Windows tree-termination failure retains ownership after the root fallback exits', () async {
        final process = FakeProcess(completeExitOnKill: true);

        final exitConfirmed = await terminateBashProcessTree(
          process,
          PlatformCapabilities(operatingSystem: 'windows'),
          rootProcessIdentity: null,
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (_) async => ProcessResult(0, 1, '', 'failed'),
        );

        expect(process.killSignals, [ProcessSignal.sigterm]);
        expect(exitConfirmed, isFalse);
      });

      test('unconfirmed Windows timeout remains owned until cleanup retry observes exit', () async {
        final process = FakeProcess();
        final owner = BashProcessOwner()
          ..track(process)
          ..markCleanupPending(process);
        final capabilities = PlatformCapabilities(operatingSystem: 'windows');

        final exitConfirmed = await terminateBashProcessTree(
          process,
          capabilities,
          rootProcessIdentity: null,
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (_) async => ProcessResult(0, 0, '', ''),
        );

        expect(exitConfirmed, isFalse);
        expect(owner.owns(process), isTrue);

        await retryOwnedBashProcesses(
          owner,
          capabilities,
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (_) async {
            process.exit(1);
            return ProcessResult(0, 0, '', '');
          },
        );

        expect(owner.owns(process), isFalse);
      });

      test('Windows cleanup retry does not terminate an already-observed root PID', () async {
        final process = FakeProcess();
        final owner = BashProcessOwner()
          ..track(process)
          ..markCleanupPending(process);
        process.exit(0);
        var terminationCalls = 0;

        await retryOwnedBashProcesses(
          owner,
          PlatformCapabilities(operatingSystem: 'windows'),
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (_) async {
            terminationCalls++;
            return ProcessResult(0, 0, '', '');
          },
        );

        expect(terminationCalls, isZero);
        expect(owner.owns(process), isFalse);
      });

      test('cleanup retry never terminates another active Bash step', () async {
        final activeProcess = FakeProcess();
        final timedOutProcess = FakeProcess();
        final owner = BashProcessOwner()
          ..track(activeProcess)
          ..track(timedOutProcess)
          ..markCleanupPending(timedOutProcess);

        await retryOwnedBashProcesses(
          owner,
          PlatformCapabilities(operatingSystem: 'windows'),
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (pid) async {
            expect(pid, timedOutProcess.pid);
            timedOutProcess.exit(1);
            return ProcessResult(0, 0, '', '');
          },
        );

        expect(activeProcess.killCalled, isFalse);
        expect(owner.owns(activeProcess), isTrue);
        expect(owner.owns(timedOutProcess), isFalse);
      });

      test('concurrent cleanup callers share one attempt and later retry after an unconfirmed result', () async {
        final process = FakeProcess();
        final owner = BashProcessOwner()
          ..track(process)
          ..markCleanupPending(process);
        final capabilities = PlatformCapabilities(operatingSystem: 'windows');
        final releaseTermination = Completer<ProcessResult>();
        var terminationCalls = 0;

        Future<ProcessResult> terminate(int _) {
          terminationCalls++;
          return releaseTermination.future;
        }

        final timeoutCleanup = owner.runCleanupAttempt(
          process,
          () => terminateBashProcessTree(
            process,
            capabilities,
            rootProcessIdentity: null,
            gracePeriod: Duration.zero,
            windowsTreeTerminator: terminate,
          ),
        );
        final concurrentCleanup = owner.runCleanupAttempt(
          process,
          () => terminateBashProcessTree(
            process,
            capabilities,
            rootProcessIdentity: null,
            gracePeriod: Duration.zero,
            windowsTreeTerminator: terminate,
          ),
        );

        await Future<void>.delayed(Duration.zero);
        expect(terminationCalls, 1);
        releaseTermination.complete(ProcessResult(0, 0, '', ''));
        expect(await Future.wait([timeoutCleanup, concurrentCleanup]), [isFalse, isFalse]);

        await retryOwnedBashProcesses(
          owner,
          capabilities,
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (_) async {
            terminationCalls++;
            return ProcessResult(0, 0, '', '');
          },
        );

        expect(terminationCalls, 2);
        expect(owner.owns(process), isTrue);
      });

      test('POSIX discovery rejects a reused child PID whose parent changed before identity capture', () async {
        const reusedPid = 101;
        final process = FakeProcess(pid: 500, completeExitOnKill: true);
        final signals = <(int, ProcessSignal)>[];

        final exitConfirmed = await terminateBashProcessTree(
          process,
          PlatformCapabilities(operatingSystem: 'linux'),
          rootProcessIdentity: 'root-start',
          gracePeriod: Duration.zero,
          posixProcessIdentityLookup: (_) async => 'reused-start',
          posixProcessSnapshotLookup: (pid) async =>
              pid == process.pid ? (identity: 'root-start', parentPid: 1) : (identity: 'reused-start', parentPid: 999),
          posixChildPidLookup: (parentPid) async => parentPid == process.pid ? const [reusedPid] : const [],
          posixProcessSignaler: (pid, signal) {
            signals.add((pid, signal));
            return true;
          },
        );

        expect(exitConfirmed, isTrue);
        expect(signals, isEmpty);
      });

      test('POSIX cleanup retry signals only descendants with the retained identity', () async {
        const reusedPid = 101;
        const ownedPid = 202;
        final process = FakeProcess(pid: 2147483646);
        final owner = BashProcessOwner()
          ..track(process)
          ..markCleanupPending(process)
          ..replaceDescendants(process, const {reusedPid: 'old-start', ownedPid: 'live-start'});
        final currentIdentities = <int, String>{reusedPid: 'reused-start', ownedPid: 'live-start'};
        final signals = <(int, ProcessSignal)>[];

        await retryOwnedBashProcesses(
          owner,
          PlatformCapabilities(operatingSystem: 'linux'),
          gracePeriod: Duration.zero,
          posixProcessIdentityLookup: (pid) async => currentIdentities[pid],
          posixProcessSignaler: (pid, signal) {
            signals.add((pid, signal));
            return true;
          },
        );

        expect(signals.where((entry) => entry.$1 == reusedPid), isEmpty);
        expect(signals.where((entry) => entry.$1 == ownedPid).map((entry) => entry.$2), [
          ProcessSignal.sigterm,
          ProcessSignal.sigkill,
        ]);
        expect(owner.descendantIdentitiesOf(process), {ownedPid: 'live-start'});
        expect(owner.owns(process), isTrue);
      });
    });

    group('resolveBashCommand', () {
      test('shell-escapes context substitutions', () {
        final command = resolveBashCommand('printf {{context.value}}', WorkflowContext(data: {'value': 'a b'}));

        expect(command, equals("printf 'a b'"));
      });

      test('shell-escapes {{VAR}} substitutions', () {
        final context = WorkflowContext(data: {}, variables: {'MSG': 'hello world'});
        final command = resolveBashCommand('echo {{MSG}}', context);

        expect(command, equals("echo 'hello world'"));
      });

      test('shell-escapes workflow system substitutions', () {
        final context = WorkflowContext(
          data: {},
          systemVariables: const {'workflow.runtime_artifacts_dir': '/tmp/runtime artifacts'},
        );
        final command = resolveBashCommand('ls {{workflow.runtime_artifacts_dir}}', context);

        expect(command, equals("ls '/tmp/runtime artifacts'"));
      });

      test('escapes malicious {{context.key}} value', () {
        final context = WorkflowContext(data: {'path': r'$(rm -rf /)'});
        final command = resolveBashCommand('ls {{context.path}}', context);

        // Single-quote wrapping neutralises the $() — it cannot expand.
        expect(command, equals(r"ls '$(rm -rf /)'"));
      });

      test('escapes malicious {{VAR}} value', () {
        final context = WorkflowContext(data: {}, variables: {'INPUT': r'; malicious'});
        final command = resolveBashCommand('run {{INPUT}}', context);

        // Single-quote wrapping neutralises the semicolon as a command separator.
        expect(command, equals("run '; malicious'"));
      });

      test('undefined {{VAR}} throws ArgumentError', () {
        final context = WorkflowContext(data: {});

        expect(
          () => resolveBashCommand('echo {{UNDEFINED}}', context),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('UNDEFINED'))),
        );
      });

      test('missing context key returns empty quoted string', () {
        final context = WorkflowContext(data: {});
        final command = resolveBashCommand('echo {{context.missing}}', context);

        expect(command, equals("echo ''"));
      });

      test('wraps a command-substitution payload in a single inert argument', () {
        final command = resolveBashCommand('echo {{context.msg}}', WorkflowContext(data: {'msg': r'a b $(id)'}));

        expect(command, equals(r"echo 'a b $(id)'"));
      });
    });

    test('extracts line outputs from stdout', () {
      final outputs = extractBashOutputs(
        const WorkflowStep(
          id: 'bash',
          name: 'Bash',
          outputs: {'lines': OutputConfig(format: OutputFormat.lines)},
        ),
        'a\nb\n',
      );

      expect(outputs['lines'], equals(['a', 'b']));
    });
  });

  group('bash step execution', () {
    final h = WorkflowExecutorHarness();
    setUp(h.setUp);
    tearDown(h.tearDown);

    test('POSIX bash step executes through /bin/sh and captures stdout', () async {
      const step = WorkflowStep(
        id: 'bash1',
        name: 'Bash 1',
        taskType: WorkflowTaskType.bash,
        prompts: ['echo hello'],
        outputs: {'out': OutputConfig()},
      );
      final run = h.makeRun(h.makeDefinition(steps: [step]));

      final outcome = await executeBashStep(
        run: run,
        step: step,
        context: WorkflowContext(),
        dataDir: h.tempDir.path,
        templateEngine: WorkflowTemplateEngine(),
        capabilities: PlatformCapabilities(operatingSystem: 'linux'),
      );

      expect(outcome.success, isTrue);
      expect(outcome.outputs['bash1.status'], 'success');
      expect(outcome.outputs['bash1.exitCode'], 0);
      expect((outcome.outputs['out'] as String).trim(), 'hello');
    });

    test('missing Git Bash returns a failed outcome, never success', () async {
      const step = WorkflowStep(id: 'bash1', name: 'Bash 1', taskType: WorkflowTaskType.bash, prompts: ['echo hello']);
      final run = h.makeRun(h.makeDefinition(steps: [step]));

      final outcome = await executeBashStep(
        run: run,
        step: step,
        context: WorkflowContext(),
        dataDir: h.tempDir.path,
        templateEngine: WorkflowTemplateEngine(),
        capabilities: PlatformCapabilities(operatingSystem: 'windows'),
        executableLookup: (executable, arguments) async => (exitCode: 1, stdout: ''),
      );

      expect(outcome.success, isFalse);
      expect(outcome.outputs['bash1.status'], 'failed');
      expect(outcome.outputs['bash1.error'], contains('bash steps require Git Bash on Windows'));
      expect(outcome.outputs['bash1.status'], isNot('success'));
    });

    test('executor honors the injected Windows capability surface', () async {
      final executor = h.makeExecutor(
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        executableLookupExecutor: (executable, arguments) async => (exitCode: 1, stdout: ''),
      );
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', taskType: WorkflowTaskType.bash, prompts: ['echo hello']),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      expect((await h.repository.getById(run.id))?.status, WorkflowRunStatus.failed);
      expect(context['bash1.status'], 'failed');
      expect(context['bash1.error'], contains('bash steps require Git Bash on Windows'));
    });

    test('bash step runs command and completes with zero tokens and no task', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', taskType: WorkflowTaskType.bash, prompts: ['echo hello']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) {
        taskIds.add(e.taskId);
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      expect(taskIds, isEmpty);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(finalRun?.totalTokens, equals(0));
    });

    test('bash step sets status=success and exitCode=0 in context', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', taskType: WorkflowTaskType.bash, prompts: ['echo ok']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      expect(context['bash1.exitCode'], equals(0));
      expect(context['bash1.tokenCount'], equals(0));
    });

    test('bash step extracts text output to context key', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['printf "captured output"'],
            outputs: {'bash1.out': OutputConfig()},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      expect(context['bash1.out'], equals('captured output'));
    });

    test('bash step extracts json output from stdout', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['printf \'{"key":"value"}\''],
            outputs: {'result': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final result = context['result'];
      expect(result, isA<Map<String, dynamic>>());
      expect((result as Map<String, dynamic>)['key'], equals('value'));
    });

    test('bash step extracts lines output from stdout', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['printf "a\\nb\\nc"'],
            outputs: {'lines': OutputConfig(format: OutputFormat.lines)},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final lines = context['lines'];
      expect(lines, isA<List<String>>());
      expect(lines as List<String>, containsAll(['a', 'b', 'c']));
    });

    test('bash step with non-zero exit pauses workflow by default', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', taskType: WorkflowTaskType.bash, prompts: ['exit 1']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('bash step with onError: continue records failure and proceeds', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['exit 42'],
            onError: OnErrorPolicy.continueWorkflow,
          ),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['bash1.status'], equals('failed'));
    });

    test('bash step uses workdir from context when template-referenced', () async {
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: const ['pwd'],
            workdir: h.tempDir.path,
            outputs: const {'cwd': OutputConfig()},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      final expected = h.tempDir.resolveSymbolicLinksSync();
      expect((context['cwd'] as String?)?.trim(), equals(expected));
    });

    test('bash step rejects workdir templates that reference context values', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['pwd'],
            workdir: '{{context.dir}}',
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext(data: {'dir': h.tempDir.path});

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(context['bash1.error'], contains('workdir must not reference context values'));
    });

    test('bash step rejects workdirs outside dataDir', () async {
      final outside = Directory.systemTemp.createTempSync('dartclaw_bash_outside_');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: const ['pwd'],
            workdir: outside.path,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(context['bash1.error'], contains('workdir escapes dataDir'));
    });

    test('bash step strips sensitive parent env and keeps allowlisted vars only', () async {
      final isolatedExecutor = h.makeExecutor(
        hostEnvironment: const {
          'PATH': '/usr/bin:/bin',
          'HOME': '/tmp/home',
          'LANG': 'en_US.UTF-8',
          'ANTHROPIC_API_KEY': 'leak-canary',
          'GITHUB_TOKEN': 'gh-leak',
          'CUSTOM_SECRET': 'dont-leak',
          'CUSTOM_ALLOWED': 'survives',
        },
        bashStepEnvAllowlist: const ['PATH', 'HOME', 'CUSTOM_ALLOWED'],
      );
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: [
              r'printf "%s|%s|%s|%s" "${ANTHROPIC_API_KEY:-missing}" "${GITHUB_TOKEN:-missing}" "${CUSTOM_SECRET:-missing}" "${CUSTOM_ALLOWED:-missing}"',
            ],
            outputs: {'bash1.out': OutputConfig()},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await isolatedExecutor.execute(run, definition, context);

      expect(context['bash1.out'], 'missing|missing|missing|survives');
    });

    test('bash step with non-existent workdir pauses workflow', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['echo x'],
            workdir: '/non/existent/dir/12345',
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    // These remain real process tests: they prove OS process-tree termination,
    // not just executor timeout bookkeeping.
    test('bash step timeout pauses workflow', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['sleep 10'],
            timeoutSeconds: 1,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
      'bash step timeout terminates the spawned process',
      () async {
        final outputFile = p.join(h.tempDir.path, 'timed-out.txt');
        final definition = h.makeDefinition(
          steps: [
            WorkflowStep(
              id: 'bash1',
              name: 'Bash 1',
              taskType: WorkflowTaskType.bash,
              prompts: ['sleep 2; echo late > "$outputFile"'],
              timeoutSeconds: 1,
            ),
          ],
        );

        final run = h.makeRun(definition);
        await h.repository.insert(run);

        await h.executor.execute(run, definition, WorkflowContext());
        await Future<void>.delayed(const Duration(milliseconds: 1500));

        expect(File(outputFile).existsSync(), isFalse);
      },
      skip: PlatformCapabilities().posixSignalsAvailable
          ? false
          : 'Native Windows Bash descendant containment is unsupported',
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'bash step timeout terminates background children',
      () async {
        final outputFile = p.join(h.tempDir.path, 'timed-out-child.txt');
        final definition = h.makeDefinition(
          steps: [
            WorkflowStep(
              id: 'bash1',
              name: 'Bash 1',
              taskType: WorkflowTaskType.bash,
              prompts: ['(sleep 2; echo late > "$outputFile") & wait'],
              timeoutSeconds: 1,
            ),
          ],
        );

        final run = h.makeRun(definition);
        await h.repository.insert(run);

        await h.executor.execute(run, definition, WorkflowContext());
        await Future<void>.delayed(const Duration(milliseconds: 1500));

        expect(File(outputFile).existsSync(), isFalse);
      },
      skip: PlatformCapabilities().posixSignalsAvailable
          ? false
          : 'Native Windows Bash descendant containment is unsupported',
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('bash step deadline includes an indefinitely backgrounded child', () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final pidFile = p.join(h.tempDir.path, 'indefinite-child.pid');
      addTearDown(() async {
        if (!File(pidFile).existsSync()) return;
        final childPid = int.tryParse(File(pidFile).readAsStringSync().trim());
        if (childPid == null) return;
        final probe = await Process.run('/bin/sh', ['-c', 'kill -0 $childPid 2>/dev/null']);
        if (probe.exitCode == 0) Process.killPid(childPid, ProcessSignal.sigkill);
      });
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['while :; do sleep 1; done & echo \$! > "$pidFile"'],
            timeoutSeconds: 1,
          ),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final stopwatch = Stopwatch()..start();

      await h.executor.execute(run, definition, WorkflowContext());
      stopwatch.stop();

      final childPid = int.parse(File(pidFile).readAsStringSync().trim());
      final probe = await Process.run('/bin/sh', ['-c', 'kill -0 $childPid 2>/dev/null']);
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, WorkflowRunStatus.failed);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(probe.exitCode, isNot(0));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('bash step timeout escalates a background child that ignores SIGTERM', () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final pidFile = p.join(h.tempDir.path, 'stubborn-child.pid');
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['(trap "" TERM; while :; do sleep 1; done) & child=\$!; echo \$child > "$pidFile"; wait'],
            timeoutSeconds: 1,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      await h.executor.execute(run, definition, WorkflowContext());

      final childPid = int.parse(File(pidFile).readAsStringSync().trim());
      final probe = await Process.run('/bin/sh', ['-c', 'kill -0 $childPid 2>/dev/null']);
      if (probe.exitCode == 0) Process.killPid(childPid, ProcessSignal.sigkill);
      expect(probe.exitCode, isNot(0));
    }, timeout: const Timeout(Duration(seconds: 12)));

    test('bash stdout is retained only up to the configured byte cap', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['yes x | head -c 70000'],
            outputs: {'out': OutputConfig()},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      expect(context['bash1.stdoutTruncated'], isTrue);
      expect((context['out'] as String).length, lessThan(66000));
      expect(context['out'], endsWith('[truncated]'));
    });

    test('bash step with json output fails on empty stdout', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['printf ""'],
            outputs: {'result': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      await h.executor.execute(run, definition, WorkflowContext());

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('bash step shell-escapes context values', () async {
      const maliciousValue = '; echo INJECTED';
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['echo SAFE {{context.val}}'],
            outputs: {'out': OutputConfig()},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext()..['val'] = maliciousValue;

      await h.executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      final out = (context['out'] as String?) ?? '';
      final lines = out.trim().split('\n');
      expect(lines, isNot(contains('INJECTED')), reason: 'injection should not execute as separate command');
      expect(lines.first, contains('SAFE'));
      expect(lines.first, contains('INJECTED'));
    });

    test('command substitution in a context value is echoed literally, not executed', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['echo {{context.msg}}'],
            outputs: {'out': OutputConfig()},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext()..['msg'] = r'a b $(id)';

      await h.executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      expect((context['out'] as String?)?.trim(), equals(r'a b $(id)'));
    });

    test('context command substitution inside bash -c is rejected before execution', () async {
      final sentinel = p.join(h.tempDir.path, 'shell-reparse-sentinel');
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            taskType: WorkflowTaskType.bash,
            prompts: ['bash -c "printf %s {{context.payload}}"'],
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext()..['payload'] = '\$(touch $sentinel)';

      await h.executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('failed'));
      expect(context['bash1.error'], contains('shell re-parsing'));
      expect(File(sentinel).existsSync(), isFalse);
    });

    for (final reparseCase in const [
      (name: 'quoted bash -c', command: 'bash -c "printf %s {{PAYLOAD}}"', substitution: true),
      (name: 'prefixed eval', command: 'command eval {{PAYLOAD}}', substitution: false),
      (name: 'absolute piped shell', command: 'printf %s {{PAYLOAD}} | /usr/bin/bash', substitution: false),
      (name: 'quoted piped shell', command: "printf %s {{PAYLOAD}} | 'sh'", substitution: false),
      (name: 'shell here-string', command: 'bash <<< {{PAYLOAD}}', substitution: false),
      (
        name: 'generated shell script',
        command: 'printf %s {{PAYLOAD}} > payload.sh; sh payload.sh',
        substitution: false,
      ),
    ]) {
      test('variable command through ${reparseCase.name} is rejected before execution', () async {
        final sentinel = p.join(h.tempDir.path, '${reparseCase.name.replaceAll(' ', '-')}-sentinel');
        final definition = h.makeDefinition(
          steps: [
            WorkflowStep(id: 'bash1', name: 'Bash 1', taskType: WorkflowTaskType.bash, prompts: [reparseCase.command]),
          ],
        );
        final payload = reparseCase.substitution ? '\$(touch $sentinel)' : 'touch $sentinel';

        final run = h.makeRun(definition);
        await h.repository.insert(run);
        final context = WorkflowContext(variables: {'PAYLOAD': payload});

        await h.executor.execute(run, definition, context);

        expect(context['bash1.status'], equals('failed'));
        expect(context['bash1.error'], contains('shell re-parsing'));
        expect(File(sentinel).existsSync(), isFalse);
      });
    }
  });

  group('onError: continue for agent steps', () {
    final h = WorkflowExecutorHarness();
    setUp(h.setUp);
    tearDown(h.tearDown);

    test('agent step with onError: continue proceeds past failure', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onError: OnErrorPolicy.continueWorkflow,
          ),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      int taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        if (taskCount == 1) {
          await h.completeTask(e.taskId, status: TaskStatus.failed);
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(taskCount, equals(2));
      expect(context['step1.status'], equals('failed'));
    });

    test('agent step without onError pauses on failure (backward compat)', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      int taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await h.completeTask(e.taskId, status: TaskStatus.failed);
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(taskCount, equals(1));
    });
  });
}
