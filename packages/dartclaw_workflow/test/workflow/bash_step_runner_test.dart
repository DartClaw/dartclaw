@Tags(['component'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        OutputFormat,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/bash_step_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  group('bash_step_runner unit', () {
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

      test('rejects context substitutions piped into a shell', () {
        expect(
          () => validateBashCommandTemplate('echo {{context.command}} | sh'),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('shell re-parsing'))),
        );
      });

      test('rejects context substitutions passed to eval with leading whitespace', () {
        expect(
          () => validateBashCommandTemplate('  eval {{context.command}}'),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('shell re-parsing'))),
        );
      });

      test('allows context substitutions as ordinary shell arguments', () {
        expect(() => validateBashCommandTemplate('printf %s {{context.value}}'), returnsNormally);
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

    test('bash step runs command and completes with zero tokens and no task', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['echo hello']),
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
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['echo ok']),
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
            type: 'bash',
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
            type: 'bash',
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
            type: 'bash',
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
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['exit 1']),
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
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['exit 42'], onError: 'continue'),
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
            type: 'bash',
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
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['pwd'], workdir: '{{context.dir}}'),
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
          WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: const ['pwd'], workdir: outside.path),
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
            type: 'bash',
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
            type: 'bash',
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

    test('bash step timeout pauses workflow', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['sleep 10'], timeoutSeconds: 1),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      await h.executor.execute(run, definition, context);

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('bash step timeout terminates the spawned process', () async {
      final outputFile = p.join(h.tempDir.path, 'timed-out.txt');
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
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
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('bash stdout is retained only up to the configured byte cap', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
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
            type: 'bash',
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
            type: 'bash',
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
  });

  group('onError: continue for agent steps', () {
    final h = WorkflowExecutorHarness();
    setUp(h.setUp);
    tearDown(h.tearDown);

    test('agent step with onError: continue proceeds past failure', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], onError: 'continue'),
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
