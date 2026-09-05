import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show MergeConflict, MergeExecutor;
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/task_tools.dart';
import 'package:dartclaw_runtime/src/task/task_review_service.dart';
import 'package:dartclaw_runtime/src/task/task_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGuard, InMemoryTaskRepository;
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';
import '../task/task_review_test_support.dart';

/// The six tools this suite covers, in registration order.
const _taskToolNames = ['task_create', 'task_review', 'task_list', 'review_list', 'task_bind', 'task_unbind'];

Future<Map<String, dynamic>> _call(
  McpProtocolHandler handler,
  String name, {
  Map<String, dynamic> arguments = const {},
}) async {
  final raw = await handler.handleRequest(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  return jsonDecode(raw!) as Map<String, dynamic>;
}

Map<String, dynamic> _result(Map<String, dynamic> response) {
  expect(response['error'], isNull, reason: 'a tool refusal must be a JSON-RPC success carrying isError');
  return response['result'] as Map<String, dynamic>;
}

String _text(Map<String, dynamic> result) =>
    ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;

Map<String, dynamic> _payload(Map<String, dynamic> result) => jsonDecode(_text(result)) as Map<String, dynamic>;

Task _task({
  required String id,
  required TaskStatus status,
  String title = 'Task',
  DateTime? createdAt,
  Map<String, dynamic>? worktreeJson,
}) => Task(
  id: id,
  title: title,
  description: 'Description of $id',
  status: status,
  createdAt: createdAt ?? DateTime.parse('2026-01-01T00:00:00Z'),
  worktreeJson: worktreeJson,
);

void main() {
  late Directory tempDir;
  late InMemoryTaskRepository repo;
  late TaskService tasks;
  late ThreadBindingStore bindings;
  late RecordingGuardAuditLogger audit;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_tools_');
    repo = InMemoryTaskRepository();
    tasks = TaskService(repo);
    bindings = ThreadBindingStore(File('${tempDir.path}/thread_bindings.json'));
    await bindings.load();
    audit = RecordingGuardAuditLogger();
  });

  tearDown(() async {
    await tasks.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TaskReviewService reviewService({MergeExecutor? mergeExecutor}) =>
      TaskReviewService(tasks: tasks, mergeExecutor: mergeExecutor, dataDir: tempDir.path);

  /// Registers the six real tools on the real dispatch seam.
  ///
  /// Guard evaluation and audit come from [McpProtocolHandler]; nothing in the
  /// tools participates, which is what the negative controls prove.
  McpProtocolHandler handlerWith({
    GuardChain? chain,
    GuardAuditLogger? sink,
    ThreadBindingStore? bindingStore,
    MergeExecutor? mergeExecutor,
  }) => McpProtocolHandler(guardChain: chain, auditLogger: sink)
    ..registerTool(TaskCreateTool(tasks: tasks))
    ..registerTool(TaskReviewTool(reviews: reviewService(mergeExecutor: mergeExecutor)))
    ..registerTool(TaskListTool(tasks: tasks))
    ..registerTool(ReviewListTool(tasks: tasks))
    ..registerTool(TaskBindTool(tasks: tasks, bindings: bindingStore))
    ..registerTool(TaskUnbindTool(bindings: bindingStore));

  McpProtocolHandler passingHandler({ThreadBindingStore? bindingStore, MergeExecutor? mergeExecutor}) => handlerWith(
    chain: GuardChain(guards: [FakeGuard.pass()]),
    sink: audit,
    bindingStore: bindingStore,
    mergeExecutor: mergeExecutor,
  );

  group('S01 task_create creates a task through the existing service', () {
    test('both calls return the full ID and status, and each dispatch wrote one allow entry', () async {
      final handler = passingHandler();

      final draft = _payload(
        _result(
          await _call(handler, 'task_create', arguments: {'title': 'Draft task', 'description': 'Leave it in draft'}),
        ),
      );
      final queued = _payload(
        _result(
          await _call(
            handler,
            'task_create',
            arguments: {'title': 'Queued task', 'description': 'Start it now', 'auto_start': true},
          ),
        ),
      );

      expect(draft['status'], 'draft');
      expect(queued['status'], 'queued');

      final stored = await tasks.list();
      expect(stored.map((task) => task.id).toSet(), {draft['task_id'], queued['task_id']});
      expect(stored.map((task) => task.createdBy).toSet(), {
        taskToolPrincipal,
      }, reason: 'the creator is host-chosen; no argument can spell it');
      // The full ID is what makes a later task_review resolvable without a
      // prefix match, so a truncated one would defeat the whole surface.
      expect(draft['task_id'], stored.firstWhere((task) => task.title == 'Draft task').id);

      expect(audit.entries.map((entry) => (entry.tool, entry.decision)), [
        ('task_create', 'allow'),
        ('task_create', 'allow'),
      ]);
    });

    test('a retired category argument is refused by the closed schema', () async {
      final schema = TaskCreateTool(tasks: tasks).inputSchema;
      expect(schema['properties'] as Map, isNot(contains('type')));

      final response = await _call(
        passingHandler(),
        'task_create',
        arguments: {'title': 'Research', 'description': 'Investigate', 'type': 'research'},
      );

      expect((response['error'] as Map<String, dynamic>)['code'], -32602);
      expect(await tasks.list(), isEmpty);
    });
  });

  group('S02 task_create cannot spell a security profile, a placement, a budget or a principal', () {
    test('the schema is closed and none of those names is a property', () {
      final schema = TaskCreateTool(tasks: tasks).inputSchema;

      expect(schema['additionalProperties'], false);
      expect((schema['properties'] as Map).keys.toSet(), {
        'title',
        'description',
        'acceptance_criteria',
        'project_id',
        'auto_start',
      });
    });

    test('every host-authority argument is rejected before dispatch and no task is created', () async {
      final handler = passingHandler();
      const forbidden = {
        'config_json': <String, dynamic>{},
        'security_profile': 'restricted',
        'provider': 'claude',
        'model': 'opus',
        'max_tokens': 1000,
        'created_by': 'someone-else',
        'container_profile': 'workspace',
      };

      for (final MapEntry(key: key, value: value) in forbidden.entries) {
        final response = await _call(
          handler,
          'task_create',
          arguments: {'title': 'Widening attempt', 'description': 'Should never be created', key: value},
        );
        expect(
          (response['error'] as Map<String, dynamic>)['code'],
          -32602,
          reason: '"$key" must be refused by schema validation, not by a runtime blocklist',
        );
      }

      expect(await tasks.list(), isEmpty);
      expect(audit.entries, isEmpty, reason: 'a schema rejection never reaches the dispatch seam');
    });
  });

  group('S03 review_list returns pending reviews oldest-first with full IDs', () {
    setUp(() async {
      // Created out of order so a repository-order pass-through cannot look
      // sorted by accident.
      await repo.insert(
        _task(id: 'r-middle', title: 'Middle', status: TaskStatus.review, createdAt: DateTime.utc(2026, 2, 2)),
      );
      await repo.insert(
        _task(id: 'r-oldest', title: 'Oldest', status: TaskStatus.review, createdAt: DateTime.utc(2026, 1, 1)),
      );
      await repo.insert(
        _task(id: 'r-newest', title: 'Newest', status: TaskStatus.review, createdAt: DateTime.utc(2026, 3, 3)),
      );
      await repo.insert(_task(id: 'q-queued', status: TaskStatus.queued, createdAt: DateTime.utc(2026, 1, 15)));
      await repo.insert(_task(id: 'a-accepted', status: TaskStatus.accepted, createdAt: DateTime.utc(2026, 2, 15)));
    });

    test('the whole list equals exactly the review tasks in ascending creation order', () async {
      final payload = _payload(_result(await _call(passingHandler(), 'review_list')));
      final reviews = (payload['reviews'] as List).cast<Map<String, dynamic>>();

      expect(reviews.map((entry) => (entry['task_id'], entry['title'])).toList(), [
        ('r-oldest', 'Oldest'),
        ('r-middle', 'Middle'),
        ('r-newest', 'Newest'),
      ]);
      expect(payload['truncated'], isFalse);
    });

    test('the repository still answers newest-first, so the ordering is the tool\'s own work', () async {
      expect((await tasks.list(status: TaskStatus.review)).map((task) => task.id).toList(), [
        'r-newest',
        'r-middle',
        'r-oldest',
      ]);
    });
  });

  group('S04 "accept the second one" resolves from the listing', () {
    test('the ID at position 2 of review_list is the only task that leaves review', () async {
      await repo.insert(_task(id: 'r-1', status: TaskStatus.review, createdAt: DateTime.utc(2026, 1, 1)));
      await repo.insert(
        _task(id: 'r-2', title: 'Second', status: TaskStatus.review, createdAt: DateTime.utc(2026, 2, 2)),
      );
      await repo.insert(_task(id: 'r-3', status: TaskStatus.review, createdAt: DateTime.utc(2026, 3, 3)));
      final handler = passingHandler();

      final listed = (_payload(_result(await _call(handler, 'review_list')))['reviews'] as List)
          .cast<Map<String, dynamic>>();
      final secondId = listed[1]['task_id'] as String;

      final accepted = _payload(
        _result(await _call(handler, 'task_review', arguments: {'task_id': secondId, 'action': 'accept'})),
      );

      expect(accepted['task_id'], 'r-2');
      expect(accepted['title'], 'Second');
      expect(accepted['status'], 'accepted');
      expect(
        {for (final task in await tasks.list()) task.id: task.status.name},
        {'r-1': 'review', 'r-2': 'accepted', 'r-3': 'review'},
        reason: 'no prefix resolution and no disambiguation dialog may touch the neighbours',
      );
    });
  });

  group('S05 task_review push-back transitions the task and reports only what it can observe', () {
    test('push_back transitions to running without claiming delivery', () async {
      await repo.insert(_task(id: 'pb-1', status: TaskStatus.review));
      // No PushBackFeedbackDelivery is wired — the stock-install shape — so a
      // response claiming delivery would be reporting something unobserved.
      final payload = _payload(
        _result(
          await _call(
            passingHandler(),
            'task_review',
            arguments: {'task_id': 'pb-1', 'action': 'push_back', 'feedback': 'Please add tests'},
          ),
        ),
      );

      expect(payload['status'], 'running');
      expect(payload['action'], 'push_back');
      expect(payload.keys, isNot(contains('delivered')));
      expect(_payload(_result(await _call(passingHandler(), 'review_list')))['reviews'], isEmpty);
    });

    test('push_back without feedback is refused by the tool, before the review service', () async {
      await repo.insert(_task(id: 'pb-2', status: TaskStatus.review));

      final result = _result(
        await _call(passingHandler(), 'task_review', arguments: {'task_id': 'pb-2', 'action': 'push_back'}),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['reason'], 'invalid_request');
      // The review service refuses a blank comment too, so the tool's own
      // message is what separates "the argument contract refused it" from
      // "the lifecycle refused it" — without it this test cannot fail.
      expect(_payload(result)['message'], 'feedback is required when action is push_back');
      expect((await tasks.get('pb-2'))!.status, TaskStatus.review);
    });

    test('feedback alongside accept or reject is refused', () async {
      await repo.insert(_task(id: 'pb-3', status: TaskStatus.review));

      final result = _result(
        await _call(
          passingHandler(),
          'task_review',
          arguments: {'task_id': 'pb-3', 'action': 'accept', 'feedback': 'looks good'},
        ),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['message'], 'feedback is only accepted when action is push_back');
      expect((await tasks.get('pb-3'))!.status, TaskStatus.review, reason: 'a refused call has no side effect');
    });
  });

  group('S06 every ReviewResult failure variant reaches the model as a distinguishable error', () {
    test('unknown ID, non-review status and a merge conflict are distinct and non-destructive', () async {
      await repo.insert(_task(id: 'draft-1', status: TaskStatus.draft));
      await repo.insert(
        _task(
          id: 'conflict-1',
          status: TaskStatus.review,
          worktreeJson: {
            'branch': 'task/conflict-1',
            'path': '${tempDir.path}/wt',
            'createdAt': '2026-01-01T00:00:00Z',
          },
        ),
      );
      final conflicted = passingHandler(
        mergeExecutor: RecordingMergeExecutor(
          result: const MergeConflict(conflictingFiles: ['lib/a.dart', 'lib/b.dart'], details: 'merge conflict'),
        ),
      );

      final missing = _result(
        await _call(passingHandler(), 'task_review', arguments: {'task_id': 'nope', 'action': 'accept'}),
      );
      final wrongStatus = _result(
        await _call(passingHandler(), 'task_review', arguments: {'task_id': 'draft-1', 'action': 'accept'}),
      );
      final conflict = _result(
        await _call(conflicted, 'task_review', arguments: {'task_id': 'conflict-1', 'action': 'accept'}),
      );

      expect([missing['isError'], wrongStatus['isError'], conflict['isError']], [isTrue, isTrue, isTrue]);
      expect(_payload(missing)['reason'], 'not_found');
      expect(_payload(wrongStatus)['reason'], 'invalid_status');
      expect(_payload(wrongStatus)['current_status'], 'draft');
      expect(_payload(conflict)['reason'], 'merge_conflict');
      expect(_payload(conflict)['conflicting_files'], ['lib/a.dart', 'lib/b.dart']);

      expect((await tasks.get('draft-1'))!.status, TaskStatus.draft);
      expect((await tasks.get('conflict-1'))!.status, TaskStatus.review);
    });
  });

  group('S07 task_list enumerates tasks with full IDs and honours its filters', () {
    setUp(() async {
      await repo.insert(_task(id: 'task-review', status: TaskStatus.review, createdAt: DateTime.utc(2026, 1, 1)));
      await repo.insert(_task(id: 'task-queued', status: TaskStatus.queued, createdAt: DateTime.utc(2026, 1, 2)));
      await repo.insert(_task(id: 'task-draft', status: TaskStatus.draft, createdAt: DateTime.utc(2026, 1, 3)));
    });

    List<String> ids(Map<String, dynamic> payload) =>
        (payload['tasks'] as List).cast<Map<String, dynamic>>().map((task) => task['task_id'] as String).toList();

    test('unfiltered and status-filtered calls each return exactly the matching tasks', () async {
      final handler = passingHandler();

      final all = _payload(_result(await _call(handler, 'task_list')));
      final byStatus = _payload(_result(await _call(handler, 'task_list', arguments: {'status': 'review'})));

      expect(ids(all).toSet(), {'task-review', 'task-queued', 'task-draft'});
      expect(all['truncated'], isFalse);
      expect(ids(byStatus), ['task-review']);
    });

    test('the declared maximum bounds the listing and reports the truncation', () async {
      final payload = _payload(_result(await _call(passingHandler(), 'task_list', arguments: {'limit': 2})));

      expect(ids(payload), hasLength(2));
      expect(payload['truncated'], isTrue);
    });

    test('an unknown filter value and an over-maximum limit are refused, not silently ignored', () async {
      final handler = passingHandler();

      final unknownStatus = _result(await _call(handler, 'task_list', arguments: {'status': 'archived'}));
      final unknownType = await _call(handler, 'task_list', arguments: {'type': 'gardening'});
      final overLimit = _result(await _call(handler, 'task_list', arguments: {'limit': 10000}));

      for (final result in [unknownStatus, overLimit]) {
        expect(result['isError'], isTrue);
        expect(_payload(result)['reason'], 'invalid_request');
      }
      expect((unknownType['error'] as Map<String, dynamic>)['code'], -32602);
    });
  });

  group('S08 task_bind binds an explicit thread and refuses every ambiguous case', () {
    setUp(() async {
      await repo.insert(_task(id: 'live-1', status: TaskStatus.running));
      await repo.insert(_task(id: 'live-2', status: TaskStatus.running));
      await repo.insert(_task(id: 'done-1', status: TaskStatus.accepted));
    });

    test('a live task and a free thread bind with the session key the HTTP route would produce', () async {
      final payload = _payload(
        _result(
          await _call(
            passingHandler(bindingStore: bindings),
            'task_bind',
            arguments: {'task_id': 'live-1', 'channel_type': 'googlechat', 'thread_id': 'spaces/AAA/threads/BBB'},
          ),
        ),
      );

      expect(payload['created'], isTrue);
      expect(payload['session_key'], SessionKey.taskSession(taskId: 'live-1'));
      final stored = bindings.lookupByThread('googlechat', 'spaces/AAA/threads/BBB')!;
      expect(stored.taskId, 'live-1');
      expect(stored.sessionKey, SessionKey.taskSession(taskId: 'live-1'));
    });

    test('a terminal task and a thread bound elsewhere are each refused by reason', () async {
      final handler = passingHandler(bindingStore: bindings);
      await _call(
        handler,
        'task_bind',
        arguments: {'task_id': 'live-1', 'channel_type': 'googlechat', 'thread_id': 'thread-taken'},
      );

      final terminal = _result(
        await _call(
          handler,
          'task_bind',
          arguments: {'task_id': 'done-1', 'channel_type': 'googlechat', 'thread_id': 'thread-free'},
        ),
      );
      final conflict = _result(
        await _call(
          handler,
          'task_bind',
          arguments: {'task_id': 'live-2', 'channel_type': 'googlechat', 'thread_id': 'thread-taken'},
        ),
      );

      expect(_payload(terminal)['reason'], 'terminal_task');
      expect(_payload(conflict)['reason'], 'thread_conflict');
      expect(_payload(conflict)['bound_task_id'], 'live-1');
      expect(bindings.lookupByThread('googlechat', 'thread-free'), isNull);
      expect(bindings.lookupByThread('googlechat', 'thread-taken')!.taskId, 'live-1');
    });

    test('a channel with no thread identity is not offered and is refused when named', () async {
      final handler = passingHandler(bindingStore: bindings);
      final schema = TaskBindTool(tasks: tasks, bindings: bindings).inputSchema;
      final channels = ((schema['properties'] as Map)['channel_type'] as Map)['enum'] as List;

      expect(channels, ['googlechat'], reason: 'only Google Chat stamps the thread id the router reads');

      final refused = _result(
        await _call(
          handler,
          'task_bind',
          arguments: {'task_id': 'live-1', 'channel_type': 'whatsapp', 'thread_id': '120363000@g.us'},
        ),
      );
      expect(refused['isError'], isTrue);
      expect(_payload(refused)['reason'], 'invalid_request');
      expect(bindings.lookupByThread('whatsapp', '120363000@g.us'), isNull);
    });

    test('binding the same task and thread twice reports the existing binding without duplicating it', () async {
      final handler = passingHandler(bindingStore: bindings);
      const args = {'task_id': 'live-1', 'channel_type': 'googlechat', 'thread_id': 'thread-repeat'};

      final first = _payload(_result(await _call(handler, 'task_bind', arguments: args)));
      final second = _result(await _call(handler, 'task_bind', arguments: args));

      expect(first['created'], isTrue);
      expect(second['isError'], isNull, reason: 'an identical binding is the state the caller asked for');
      expect(_payload(second)['created'], isFalse);
      expect(bindings.lookupByTask('live-1'), hasLength(1));
    });
  });

  group('S09 task_unbind removes every binding for a task and says so when there were none', () {
    test('both bindings are removed, the count is reported, and the removal survives a reload', () async {
      await repo.insert(_task(id: 'bound-1', status: TaskStatus.running));
      final handler = passingHandler(bindingStore: bindings);
      for (final thread in ['thread-a', 'thread-b']) {
        await _call(
          handler,
          'task_bind',
          arguments: {'task_id': 'bound-1', 'channel_type': 'googlechat', 'thread_id': thread},
        );
      }

      final payload = _payload(_result(await _call(handler, 'task_unbind', arguments: {'task_id': 'bound-1'})));
      expect(payload['removed'], 2);
      expect(bindings.lookupByTask('bound-1'), isEmpty);

      // The reported count must already be durable — `task_unbind` returns only
      // after `deleteByTaskId` has persisted.
      final reloaded = ThreadBindingStore(File('${tempDir.path}/thread_bindings.json'));
      await reloaded.load();
      expect(reloaded.lookupByTask('bound-1'), isEmpty, reason: 'the removal must outlive the in-memory map');
    });

    test('unbinding a task with no bindings is a success stating that none existed', () async {
      final result = _result(
        await _call(passingHandler(bindingStore: bindings), 'task_unbind', arguments: {'task_id': 'never-bound'}),
      );

      expect(result['isError'], isNull);
      expect(_payload(result)['removed'], 0);
    });
  });

  group('S10 negative control: the binding tools refuse cleanly when no binding store is wired', () {
    test('both report the disabled store as a tool error rather than throwing or succeeding', () async {
      await repo.insert(_task(id: 'live-1', status: TaskStatus.running));
      final handler = passingHandler();

      final bind = _result(
        await _call(
          handler,
          'task_bind',
          arguments: {'task_id': 'live-1', 'channel_type': 'googlechat', 'thread_id': 'thread-x'},
        ),
      );
      final unbind = _result(await _call(handler, 'task_unbind', arguments: {'task_id': 'live-1'}));

      for (final result in [bind, unbind]) {
        expect(result['isError'], isTrue);
        expect(_payload(result)['reason'], 'thread_binding_not_enabled');
      }
    });
  });

  group('S11 negative control: a guard block refuses each of the six tools with no side effect', () {
    test('all six are JSON-RPC successes carrying isError, with one deny entry each and no state change', () async {
      await repo.insert(_task(id: 'guarded-1', status: TaskStatus.review, createdAt: DateTime.utc(2026, 1, 1)));
      await bindings.create(
        ThreadBinding(
          channelType: 'googlechat',
          threadId: 'guarded-thread',
          taskId: 'guarded-1',
          sessionKey: SessionKey.taskSession(taskId: 'guarded-1'),
          createdAt: DateTime.utc(2026, 1, 1),
          lastActivity: DateTime.utc(2026, 1, 1),
        ),
      );
      final handler = handlerWith(
        chain: GuardChain(guards: [FakeGuard.block('mcp task tools disabled')]),
        sink: audit,
        bindingStore: bindings,
      );

      const argumentsByTool = <String, Map<String, dynamic>>{
        'task_create': {'title': 'Blocked', 'description': 'Blocked'},
        'task_review': {'task_id': 'guarded-1', 'action': 'accept'},
        'task_list': <String, dynamic>{},
        'review_list': <String, dynamic>{},
        'task_bind': {'task_id': 'guarded-1', 'channel_type': 'googlechat', 'thread_id': 'free-thread'},
        'task_unbind': {'task_id': 'guarded-1'},
      };

      for (final name in _taskToolNames) {
        final result = _result(await _call(handler, name, arguments: argumentsByTool[name]!));
        expect(result['isError'], isTrue, reason: '$name must refuse as a tool error, not a protocol error');
        expect(_text(result), 'mcp task tools disabled');
      }

      expect(
        audit.entries.map((entry) => entry.tool).toList(),
        _taskToolNames,
        reason: 'one deny entry per call, naming the tool the seam refused',
      );
      expect(audit.entries.map((entry) => entry.decision).toSet(), {'deny'});

      expect(await tasks.list(), hasLength(1));
      expect((await tasks.get('guarded-1'))!.status, TaskStatus.review);
      expect(bindings.lookupByThread('googlechat', 'free-thread'), isNull);
      expect(bindings.lookupByTask('guarded-1'), hasLength(1));
    });
  });

  group('the declared argument contract is enforced for every tool', () {
    setUp(() async {
      await repo.insert(_task(id: 'arg-1', status: TaskStatus.review));
    });

    // One row per validator branch the six schemas can reach: a missing
    // required property, a wrong declared type, a blank string, and each
    // integer bound. The seam only rejects arguments the schema does not name.
    const cases = <({String tool, Map<String, dynamic> arguments, String message})>[
      (tool: 'task_create', arguments: {'description': 'no title'}, message: 'title is required'),
      (tool: 'task_review', arguments: {'action': 'accept'}, message: 'task_id is required'),
      (
        tool: 'task_bind',
        arguments: {'task_id': 'arg-1', 'channel_type': 'googlechat'},
        message: 'thread_id is required',
      ),
      (tool: 'task_unbind', arguments: {}, message: 'task_id is required'),
      (
        tool: 'task_create',
        arguments: {'title': 'T', 'description': 'D', 'auto_start': 'yes'},
        message: 'auto_start must be a boolean',
      ),
      (tool: 'task_list', arguments: {'limit': '10'}, message: 'limit must be an integer'),
      (tool: 'task_list', arguments: {'limit': 0}, message: 'limit must be at least 1'),
      (tool: 'task_list', arguments: {'limit': 201}, message: 'limit must be at most 200'),
      (
        tool: 'task_create',
        arguments: {'title': '   ', 'description': 'D'},
        message: 'title must be a non-empty string',
      ),
      (
        tool: 'task_review',
        arguments: {'task_id': 'arg-1', 'action': 'approve'},
        message: 'action must be one of: accept, reject, push_back',
      ),
    ];

    for (final testCase in cases) {
      test('${testCase.tool}: ${testCase.message}', () async {
        final handler = passingHandler(bindingStore: bindings);

        final result = _result(await _call(handler, testCase.tool, arguments: testCase.arguments));

        expect(result['isError'], isTrue);
        expect(_payload(result)['reason'], 'invalid_request');
        expect(_payload(result)['message'], testCase.message);
        // Fail-closed means the refused call also left nothing behind.
        expect(await tasks.list(), hasLength(1));
        expect((await tasks.get('arg-1'))!.status, TaskStatus.review);
        expect(bindings.lookupByTask('arg-1'), isEmpty);
      });
    }
  });

  group('read/write classification and closed schemas', () {
    test('the four mutating tools are write-classified and the two listings are read-classified', () {
      final handler = passingHandler(bindingStore: bindings);

      expect(handler.toolAccess, containsPair('task_create', McpToolAccess.write));
      expect(handler.toolAccess, containsPair('task_review', McpToolAccess.write));
      expect(handler.toolAccess, containsPair('task_bind', McpToolAccess.write));
      expect(handler.toolAccess, containsPair('task_unbind', McpToolAccess.write));
      expect(handler.toolAccess, containsPair('task_list', McpToolAccess.read));
      expect(handler.toolAccess, containsPair('review_list', McpToolAccess.read));
    });

    test('no schema property in any of the six can reach a host decision', () {
      final tools = <McpTool>[
        TaskCreateTool(tasks: tasks),
        TaskReviewTool(reviews: reviewService()),
        TaskListTool(tasks: tasks),
        ReviewListTool(tasks: tasks),
        TaskBindTool(tasks: tasks, bindings: bindings),
        TaskUnbindTool(bindings: bindings),
      ];
      const hostOwned = {
        'security_profile',
        'container_profile',
        'mount',
        'mounts',
        'provider',
        'model',
        'max_tokens',
        'token_budget',
        'created_by',
        'principal',
        'config_json',
      };

      expect(tools.map((tool) => tool.name).toList(), _taskToolNames);
      for (final tool in tools) {
        final schema = tool.inputSchema;
        expect(schema['additionalProperties'], false, reason: '${tool.name} must declare a closed schema');
        expect((schema['properties'] as Map).keys.toSet().intersection(hostOwned), isEmpty, reason: tool.name);
      }
    });
  });
}
