import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

SubscriptionRecord sampleRecord({
  String spaceId = 'SPACE_1',
  String subscriptionName = 'subscriptions/sub-1',
  DateTime? expireTime,
  DateTime? createdAt,
}) {
  final now = DateTime.now().toUtc();
  return SubscriptionRecord(
    spaceId: spaceId,
    subscriptionName: subscriptionName,
    expireTime: expireTime ?? now.add(const Duration(hours: 4)),
    createdAt: createdAt ?? now,
  );
}

SpaceEventsConfig testConfig({
  String pubsubTopic = 'projects/my-project/topics/dartclaw-chat-events',
  List<String> eventTypes = const ['message.created'],
  bool includeResource = true,
}) {
  return SpaceEventsConfig(
    enabled: true,
    pubsubTopic: pubsubTopic,
    eventTypes: eventTypes,
    includeResource: includeResource,
  );
}

/// Creates a mock HTTP client that responds to Workspace Events API calls.
MockClient createMockClient({
  int createStatus = 200,
  Map<String, dynamic>? createResponse,
  int patchStatus = 200,
  Map<String, dynamic>? patchResponse,
  int deleteStatus = 200,
  int getStatus = 200,
  Map<String, dynamic>? getResponse,
  void Function(http.Request)? onRequest,
}) {
  return MockClient((request) async {
    onRequest?.call(request);
    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith('/subscriptions')) {
      return http.Response(
        jsonEncode(
          createResponse ??
              {
                'name': 'subscriptions/new-sub-1',
                'expireTime': DateTime.now().toUtc().add(const Duration(hours: 4)).toIso8601String(),
                'state': 'ACTIVE',
              },
        ),
        createStatus,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'PATCH') {
      return http.Response(
        jsonEncode(
          patchResponse ??
              {
                'name': 'subscriptions/new-sub-1',
                'expireTime': DateTime.now().toUtc().add(const Duration(hours: 4)).toIso8601String(),
                'state': 'ACTIVE',
              },
        ),
        patchStatus,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'DELETE') {
      return http.Response('{}', deleteStatus);
    }
    if (request.method == 'GET') {
      return http.Response(
        jsonEncode(
          getResponse ??
              {
                'name': 'subscriptions/new-sub-1',
                'expireTime': DateTime.now().toUtc().add(const Duration(hours: 4)).toIso8601String(),
                'state': 'ACTIVE',
              },
        ),
        getStatus,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('Not found', 404);
  });
}

WorkspaceEventsManager makeManager({
  required http.Client mockClient,
  required Directory dataDir,
  SpaceEventsConfig? config,
  SpaceDiscoveryCallback? discoverSpaces,
  Future<void> Function(Duration)? delay,
  DateTime Function()? clock,
}) {
  return WorkspaceEventsManager(
    authClient: mockClient,
    config: config ?? testConfig(),
    dataDir: dataDir.path,
    discoverSpaces: discoverSpaces,
    delay: delay ?? (_) async {},
    clock: clock,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('workspace_events_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('SubscriptionRecord', () {
    test('toJson serializes all fields', () {
      final now = DateTime.utc(2024, 3, 15, 10, 30);
      final expire = DateTime.utc(2024, 3, 15, 14, 30);
      final record = SubscriptionRecord(
        spaceId: 'SPACE_1',
        subscriptionName: 'subscriptions/abc123',
        expireTime: expire,
        createdAt: now,
      );
      final json = record.toJson();
      expect(json['spaceId'], 'SPACE_1');
      expect(json['subscriptionName'], 'subscriptions/abc123');
      expect(json['expireTime'], expire.toIso8601String());
      expect(json['createdAt'], now.toIso8601String());
    });

    test('fromJson parses all fields', () {
      final now = DateTime.utc(2024, 3, 15, 10, 30);
      final expire = DateTime.utc(2024, 3, 15, 14, 30);
      final record = SubscriptionRecord(
        spaceId: 'SPACE_1',
        subscriptionName: 'subscriptions/abc123',
        expireTime: expire,
        createdAt: now,
      );
      final roundTripped = SubscriptionRecord.fromJson(record.toJson());
      expect(roundTripped.spaceId, record.spaceId);
      expect(roundTripped.subscriptionName, record.subscriptionName);
      expect(roundTripped.expireTime, record.expireTime);
      expect(roundTripped.createdAt, record.createdAt);
    });

    test('isExpired returns true for past expireTime', () {
      final record = sampleRecord(expireTime: DateTime.now().toUtc().subtract(const Duration(hours: 1)));
      expect(record.isExpired, isTrue);
    });

    test('isExpired returns false for future expireTime', () {
      final record = sampleRecord(expireTime: DateTime.now().toUtc().add(const Duration(hours: 1)));
      expect(record.isExpired, isFalse);
    });

    test('copyWith updates specified fields', () {
      final original = sampleRecord();
      final newExpire = DateTime.now().toUtc().add(const Duration(hours: 8));
      final updated = original.copyWith(subscriptionName: 'subscriptions/new-sub', expireTime: newExpire);
      expect(updated.spaceId, original.spaceId);
      expect(updated.subscriptionName, 'subscriptions/new-sub');
      expect(updated.expireTime, newExpire);
      expect(updated.createdAt, original.createdAt);
    });
  });

  group('expandEventTypes', () {
    test('expands shorthand to fully-qualified form', () {
      final result = WorkspaceEventsManager.expandEventTypes(['message.created', 'message.updated']);
      expect(result, ['google.workspace.chat.message.v1.created', 'google.workspace.chat.message.v1.updated']);
    });

    test('passes through already-qualified types', () {
      const qualified = 'google.workspace.chat.message.v1.created';
      final result = WorkspaceEventsManager.expandEventTypes([qualified]);
      expect(result, [qualified]);
    });

    test('handles mixed shorthand and qualified', () {
      const qualified = 'google.workspace.chat.reaction.v1.created';
      final result = WorkspaceEventsManager.expandEventTypes([qualified, 'message.deleted']);
      expect(result, [qualified, 'google.workspace.chat.message.v1.deleted']);
    });

    test('passes through malformed shorthand without dot', () {
      final result = WorkspaceEventsManager.expandEventTypes(['invalid']);
      expect(result, ['invalid']);
    });

    test('expands all supported resource types', () {
      final result = WorkspaceEventsManager.expandEventTypes([
        'reaction.created',
        'membership.updated',
        'space.deleted',
      ]);
      expect(result, [
        'google.workspace.chat.reaction.v1.created',
        'google.workspace.chat.membership.v1.updated',
        'google.workspace.chat.space.v1.deleted',
      ]);
    });
  });

  group('normalizeSpaceId', () {
    test('strips spaces/ prefix', () {
      expect(WorkspaceEventsManager.normalizeSpaceId('spaces/AAABBBCCC'), 'AAABBBCCC');
    });

    test('returns bare ID unchanged', () {
      expect(WorkspaceEventsManager.normalizeSpaceId('AAABBBCCC'), 'AAABBBCCC');
    });

    test('handles only prefix', () {
      expect(WorkspaceEventsManager.normalizeSpaceId('spaces/'), '');
    });
  });

  group('subscribe', () {
    test('normalizes spaces/ prefix from webhook-style IDs', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      // Webhook sends full resource name like 'spaces/AAABBBCCC'
      final record = await manager.subscribe('spaces/AAABBBCCC');

      expect(record, isNotNull);
      expect(record!.spaceId, 'AAABBBCCC');

      // Verify target_resource is correctly formed (no double spaces/)
      final post = requests.firstWhere((r) => r.method == 'POST');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['targetResource'], '//chat.googleapis.com/spaces/AAABBBCCC');
    });

    test('creates subscription via REST API and persists', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      final record = await manager.subscribe('SPACE_1');

      expect(record, isNotNull);
      expect(record!.spaceId, 'SPACE_1');
      expect(record.subscriptionName, 'subscriptions/new-sub-1');

      // Verify POST request
      final post = requests.firstWhere((r) => r.method == 'POST');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['targetResource'], '//chat.googleapis.com/spaces/SPACE_1');
      expect(body['eventTypes'], isNotEmpty);
      expect(body['eventTypes'][0], contains('google.workspace.chat.'));
      expect(body['notificationEndpoint']['pubsubTopic'], isNotEmpty);
      expect(body['payloadOptions']['includeResource'], isTrue);

      // Verify persisted to disk
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      expect(file.existsSync(), isTrue);
      final persisted = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(persisted['subscriptions'], hasLength(1));
      expect(persisted['subscriptions'][0]['spaceId'], 'SPACE_1');
    });

    test('returns existing subscription if not expired', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      final first = await manager.subscribe('SPACE_1');
      final second = await manager.subscribe('SPACE_1');

      expect(first, isNotNull);
      expect(second, isNotNull);
      // Only one POST should have been made
      expect(requests.where((r) => r.method == 'POST').length, 1);
      expect(second!.subscriptionName, first!.subscriptionName);
    });

    test('returns null on API error', () async {
      final manager = makeManager(mockClient: createMockClient(createStatus: 500), dataDir: tempDir);
      addTearDown(manager.dispose);

      final result = await manager.subscribe('SPACE_1');
      expect(result, isNull);

      // No file should be written
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      expect(file.existsSync(), isFalse);
    });

    test('expands event types in request body', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
        config: testConfig(eventTypes: ['message.created', 'message.deleted']),
      );
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');

      final post = requests.firstWhere((r) => r.method == 'POST');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      final eventTypes = (body['eventTypes'] as List).cast<String>();
      expect(eventTypes, contains('google.workspace.chat.message.v1.created'));
      expect(eventTypes, contains('google.workspace.chat.message.v1.deleted'));
    });

    test('does nothing when disposed', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      manager.dispose();

      final result = await manager.subscribe('SPACE_1');
      expect(result, isNull);
      expect(requests, isEmpty);
    });

    group('409 recovery', () {
      test('recovers an existing subscription from error.details metadata', () async {
        final requests = <http.Request>[];
        final manager = makeManager(
          mockClient: createMockClient(
            createStatus: 409,
            createResponse: {
              'error': {
                'details': [
                  {
                    'metadata': {'name': 'subscriptions/existing-sub'},
                  },
                ],
              },
            },
            getResponse: {
              'name': 'subscriptions/existing-sub',
              'expireTime': '2024-03-15T14:30:00Z',
              'state': 'ACTIVE',
            },
            onRequest: requests.add,
          ),
          dataDir: tempDir,
          clock: () => DateTime.utc(2024, 3, 15, 10, 30),
        );
        addTearDown(manager.dispose);

        final record = await manager.subscribe('SPACE_1');

        expect(record, isNotNull);
        expect(record!.subscriptionName, 'subscriptions/existing-sub');
        expect(record.expireTime, DateTime.utc(2024, 3, 15, 14, 30));
        expect(requests.map((request) => request.method), ['POST', 'GET']);
      });

      test('recovers an existing subscription from the error.message fallback', () async {
        final requests = <http.Request>[];
        final manager = makeManager(
          mockClient: createMockClient(
            createStatus: 409,
            createResponse: {
              'error': {'message': 'Request failed with ALREADY_EXISTS: subscriptions/from-message'},
            },
            getResponse: {
              'name': 'subscriptions/from-message',
              'expireTime': '2024-03-15T14:30:00Z',
              'state': 'ACTIVE',
            },
            onRequest: requests.add,
          ),
          dataDir: tempDir,
          clock: () => DateTime.utc(2024, 3, 15, 10, 30),
        );
        addTearDown(manager.dispose);

        final record = await manager.subscribe('SPACE_1');

        expect(record, isNotNull);
        expect(record!.subscriptionName, 'subscriptions/from-message');
        expect(requests.map((request) => request.method), ['POST', 'GET']);
      });

      test('returns null when the 409 body is unparseable', () async {
        final requests = <http.Request>[];
        final manager = WorkspaceEventsManager(
          authClient: MockClient((request) async {
            requests.add(request);
            if (request.method == 'POST') {
              return http.Response('not-json', 409);
            }
            fail('unexpected follow-up request: ${request.method} ${request.url}');
          }),
          config: testConfig(),
          dataDir: tempDir.path,
          delay: (_) async {},
        );
        addTearDown(manager.dispose);

        final record = await manager.subscribe('SPACE_1');

        expect(record, isNull);
        expect(requests.map((request) => request.method), ['POST']);
      });

      test('returns null when the recovered subscription is not ACTIVE', () async {
        final requests = <http.Request>[];
        final manager = makeManager(
          mockClient: createMockClient(
            createStatus: 409,
            createResponse: {
              'error': {
                'details': [
                  {
                    'metadata': {'name': 'subscriptions/existing-sub'},
                  },
                ],
              },
            },
            getResponse: {
              'name': 'subscriptions/existing-sub',
              'expireTime': '2024-03-15T14:30:00Z',
              'state': 'SUSPENDED',
            },
            onRequest: requests.add,
          ),
          dataDir: tempDir,
        );
        addTearDown(manager.dispose);

        final record = await manager.subscribe('SPACE_1');

        expect(record, isNull);
        expect(requests.map((request) => request.method), ['POST', 'GET']);
      });

      test('persists and schedules renewal when recovery returns ACTIVE with expireTime', () async {
        final delays = <Duration>[];
        final manager = makeManager(
          mockClient: createMockClient(
            createStatus: 409,
            createResponse: {
              'error': {
                'details': [
                  {
                    'metadata': {'name': 'subscriptions/existing-sub'},
                  },
                ],
              },
            },
            getResponse: {
              'name': 'subscriptions/existing-sub',
              'expireTime': '2024-03-15T14:30:00Z',
              'state': 'ACTIVE',
            },
          ),
          dataDir: tempDir,
          clock: () => DateTime.utc(2024, 3, 15, 10, 30),
          delay: (duration) async {
            delays.add(duration);
          },
        );
        addTearDown(manager.dispose);

        final record = await manager.subscribe('SPACE_1');

        expect(record, isNotNull);
        final file = File('${tempDir.path}/google-chat-subscriptions.json');
        expect(file.existsSync(), isTrue);
        final persisted = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(persisted['subscriptions'], [
          {
            'spaceId': 'SPACE_1',
            'subscriptionName': 'subscriptions/existing-sub',
            'expireTime': '2024-03-15T14:30:00.000Z',
            'createdAt': '2024-03-15T10:30:00.000Z',
          },
        ]);
        expect(delays, [const Duration(hours: 3)]);
      });
    });
  });

  group('unsubscribe', () {
    test('deletes subscription via API and removes from persistence', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');
      final deleted = await manager.unsubscribe('SPACE_1');

      expect(deleted, isTrue);
      expect(manager.subscriptions.containsKey('SPACE_1'), isFalse);

      // Verify DELETE request
      expect(requests.any((r) => r.method == 'DELETE'), isTrue);

      // Verify JSON file updated
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      final persisted = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((persisted['subscriptions'] as List), isEmpty);
    });

    test('returns true for non-existent subscription', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      final result = await manager.unsubscribe('NON_EXISTENT');
      expect(result, isTrue);
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    });

    test('handles 404 on delete gracefully', () async {
      final manager = makeManager(mockClient: createMockClient(deleteStatus: 404), dataDir: tempDir);
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');
      final result = await manager.unsubscribe('SPACE_1');

      expect(result, isTrue);
      expect(manager.subscriptions.containsKey('SPACE_1'), isFalse);
    });

    test('handles API error on delete — record still removed from local state', () async {
      final manager = makeManager(mockClient: createMockClient(deleteStatus: 500), dataDir: tempDir);
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');
      final result = await manager.unsubscribe('SPACE_1');

      expect(result, isFalse);
      // Record still removed from local state
      expect(manager.subscriptions.containsKey('SPACE_1'), isFalse);
    });
  });

  group('renewal', () {
    test('renewal fires at approximately 75% of TTL', () async {
      final delays = <Duration>[];
      final renewalDelayCapture = Completer<Duration>();
      final manager = makeManager(
        mockClient: createMockClient(),
        dataDir: tempDir,
        delay: (d) async {
          delays.add(d);
          if (!renewalDelayCapture.isCompleted) renewalDelayCapture.complete(d);
        },
      );
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');

      // Wait briefly for scheduling to happen
      await Future<void>.delayed(Duration.zero);

      // The renewal should be scheduled at 75% of 4h = 3h
      // With a 0-delay mock, the first delay is the reconciliation pause, so check for 3h delay
      final renewalDelay = delays.where((d) => d.inMinutes >= 150).firstOrNull; // ~3h
      expect(renewalDelay, isNotNull, reason: 'Expected a ~3h renewal delay to be scheduled');
    });

    test('renewal PATCHes active subscription', () async {
      final requests = <http.Request>[];
      final patchDone = Completer<void>();

      final manager = WorkspaceEventsManager(
        authClient: MockClient((request) async {
          requests.add(request);
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'name': 'subscriptions/sub-1',
                'expireTime': DateTime.now().toUtc().add(const Duration(hours: 4)).toIso8601String(),
                'state': 'ACTIVE',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'PATCH') {
            if (!patchDone.isCompleted) patchDone.complete();
            return http.Response(
              jsonEncode({
                'name': 'subscriptions/sub-1',
                'expireTime': DateTime.now().toUtc().add(const Duration(hours: 4)).toIso8601String(),
                'state': 'ACTIVE',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        }),
        config: testConfig(),
        dataDir: tempDir.path,
        // Zero delay so renewal triggers immediately
        delay: (_) async {},
      );
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');

      // Wait for PATCH
      await patchDone.future.timeout(const Duration(seconds: 2));

      final patches = requests.where((r) => r.method == 'PATCH').toList();
      expect(patches, isNotEmpty);
      final patchBody = jsonDecode(patches.first.body) as Map<String, dynamic>;
      expect(patchBody['ttl'], endsWith('s'));
    });

    test('renewal recreates expired subscription on reconcile', () async {
      // Write a subscription that is already expired to disk
      final expiredTime = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      file.writeAsStringSync(
        jsonEncode({
          'subscriptions': [
            {
              'spaceId': 'SPACE_1',
              'subscriptionName': 'subscriptions/sub-expired',
              'expireTime': expiredTime.toIso8601String(),
              'createdAt': DateTime.now().toUtc().subtract(const Duration(hours: 5)).toIso8601String(),
            },
          ],
        }),
      );

      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      await manager.reconcile();

      // Expired subscription: DELETE + POST (recreate, not renew)
      expect(requests.any((r) => r.method == 'DELETE'), isTrue);
      expect(requests.any((r) => r.method == 'POST'), isTrue);
      // New subscription should be tracked
      expect(manager.subscriptions.containsKey('SPACE_1'), isTrue);
    });

    test('renewal handles 404 by recreating', () async {
      final requests = <http.Request>[];
      final recreateDone = Completer<void>();
      var createCount = 0;

      final manager = WorkspaceEventsManager(
        authClient: MockClient((request) async {
          requests.add(request);
          if (request.method == 'POST') {
            createCount++;
            if (createCount >= 2 && !recreateDone.isCompleted) recreateDone.complete();
            return http.Response(
              jsonEncode({
                'name': 'subscriptions/sub-$createCount',
                'expireTime': DateTime.now().toUtc().add(const Duration(hours: 4)).toIso8601String(),
                'state': 'ACTIVE',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'PATCH') {
            return http.Response('not found', 404);
          }
          return http.Response('{}', 200);
        }),
        config: testConfig(),
        dataDir: tempDir.path,
        delay: (_) async {},
      );
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');
      // Wait for recreation after 404 on PATCH
      await recreateDone.future.timeout(const Duration(seconds: 2));

      expect(createCount, greaterThanOrEqualTo(2));
    });

    test('renewal cancellation on dispose', () async {
      var patchCalled = false;
      final manager = WorkspaceEventsManager(
        authClient: MockClient((request) async {
          if (request.method == 'PATCH') {
            patchCalled = true;
          }
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'name': 'subscriptions/sub-1',
                'expireTime': DateTime.now().toUtc().add(const Duration(hours: 4)).toIso8601String(),
                'state': 'ACTIVE',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        }),
        config: testConfig(),
        dataDir: tempDir.path,
        // Real delay — will be interrupted by dispose
        delay: (d) async => Future<void>.delayed(d),
      );

      await manager.subscribe('SPACE_1');
      manager.dispose();

      // Give some time — no PATCH should be called
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(patchCalled, isFalse);
    });
  });

  group('reconcile', () {
    test('loads and verifies active subscriptions', () async {
      // Write a subscriptions JSON file
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      final expireTime = DateTime.now().toUtc().add(const Duration(hours: 2));
      file.writeAsStringSync(
        jsonEncode({
          'subscriptions': [
            {
              'spaceId': 'SPACE_1',
              'subscriptionName': 'subscriptions/sub-1',
              'expireTime': expireTime.toIso8601String(),
              'createdAt': DateTime.now().toUtc().toIso8601String(),
            },
          ],
        }),
      );

      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      await manager.reconcile();

      expect(manager.subscriptions.containsKey('SPACE_1'), isTrue);
      // Verify GET was called
      expect(requests.any((r) => r.method == 'GET'), isTrue);
    });

    test('recreates expired subscriptions', () async {
      final expiredTime = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      file.writeAsStringSync(
        jsonEncode({
          'subscriptions': [
            {
              'spaceId': 'SPACE_1',
              'subscriptionName': 'subscriptions/sub-expired',
              'expireTime': expiredTime.toIso8601String(),
              'createdAt': DateTime.now().toUtc().subtract(const Duration(hours: 5)).toIso8601String(),
            },
          ],
        }),
      );

      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      await manager.reconcile();

      // Verify DELETE + POST
      expect(requests.any((r) => r.method == 'DELETE'), isTrue);
      expect(requests.any((r) => r.method == 'POST'), isTrue);
      // Subscription should be recreated
      expect(manager.subscriptions.containsKey('SPACE_1'), isTrue);
    });

    test('handles missing subscriptions (404 on GET)', () async {
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      final expireTime = DateTime.now().toUtc().add(const Duration(hours: 2));
      file.writeAsStringSync(
        jsonEncode({
          'subscriptions': [
            {
              'spaceId': 'SPACE_1',
              'subscriptionName': 'subscriptions/sub-1',
              'expireTime': expireTime.toIso8601String(),
              'createdAt': DateTime.now().toUtc().toIso8601String(),
            },
          ],
        }),
      );

      final manager = makeManager(mockClient: createMockClient(getStatus: 404), dataDir: tempDir);
      addTearDown(manager.dispose);

      await manager.reconcile();

      // Should have created a new subscription
      expect(manager.subscriptions.containsKey('SPACE_1'), isTrue);
    });

    test('prunes records when recreation fails', () async {
      final expiredTime = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      file.writeAsStringSync(
        jsonEncode({
          'subscriptions': [
            {
              'spaceId': 'SPACE_1',
              'subscriptionName': 'subscriptions/sub-expired',
              'expireTime': expiredTime.toIso8601String(),
              'createdAt': DateTime.now().toUtc().subtract(const Duration(hours: 5)).toIso8601String(),
            },
          ],
        }),
      );

      final manager = makeManager(mockClient: createMockClient(createStatus: 500), dataDir: tempDir);
      addTearDown(manager.dispose);

      await manager.reconcile();

      // Record pruned since recreation failed
      expect(manager.subscriptions.containsKey('SPACE_1'), isFalse);
    });

    test('handles empty persisted file', () async {
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      file.writeAsStringSync(jsonEncode({'subscriptions': []}));

      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      await manager.reconcile();

      expect(requests, isEmpty);
      expect(manager.subscriptions, isEmpty);
    });

    test('handles missing persisted file', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
      );
      addTearDown(manager.dispose);

      await manager.reconcile();

      expect(requests, isEmpty);
      expect(manager.subscriptions, isEmpty);
    });

    test('respects rate limit delay between API calls', () async {
      final delays = <Duration>[];
      final expireTime = DateTime.now().toUtc().add(const Duration(hours: 2));
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      // Write 3 records
      file.writeAsStringSync(
        jsonEncode({
          'subscriptions': [
            for (var i = 1; i <= 3; i++)
              {
                'spaceId': 'SPACE_$i',
                'subscriptionName': 'subscriptions/sub-$i',
                'expireTime': expireTime.toIso8601String(),
                'createdAt': DateTime.now().toUtc().toIso8601String(),
              },
          ],
        }),
      );

      final manager = WorkspaceEventsManager(
        authClient: createMockClient(),
        config: testConfig(),
        dataDir: tempDir.path,
        delay: (d) async => delays.add(d),
      );
      addTearDown(manager.dispose);

      await manager.reconcile();

      // Should have at least 2 rate-limit delays (between 3 records)
      final rateLimitDelays = delays.where((d) => d.inMilliseconds == 200).toList();
      expect(rateLimitDelays.length, greaterThanOrEqualTo(2));
    });
  });

  group('reconcile with space discovery', () {
    test('discovers and subscribes when persisted storage is empty', () async {
      final requests = <http.Request>[];
      final callbackHits = <String>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
        discoverSpaces: () async {
          callbackHits.add('called');
          return ['SPACE_A', 'SPACE_B'];
        },
      );
      addTearDown(manager.dispose);

      await expectLater(manager.reconcile(), completes);

      expect(callbackHits, ['called']);
      expect(requests.where((request) => request.method == 'POST'), hasLength(2));
      expect(manager.subscriptions.keys, containsAll(['SPACE_A', 'SPACE_B']));
    });

    test('skips spaces that are already subscribed', () async {
      final requests = <http.Request>[];
      final existing = sampleRecord(spaceId: 'SPACE_A');
      File('${tempDir.path}/google-chat-subscriptions.json').writeAsStringSync(
        jsonEncode({
          'subscriptions': [existing.toJson()],
        }),
      );

      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
        discoverSpaces: () async => ['SPACE_A', 'SPACE_B'],
      );
      addTearDown(manager.dispose);

      await expectLater(manager.reconcile(), completes);

      expect(requests.where((request) => request.method == 'POST'), hasLength(1));
      expect(manager.subscriptions.keys, containsAll(['SPACE_A', 'SPACE_B']));
    });

    test('swallows discovery callback errors and completes reconcile', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
        discoverSpaces: () => throw StateError('boom'),
      );
      addTearDown(manager.dispose);

      await expectLater(manager.reconcile(), completes);

      expect(requests, isEmpty);
    });

    test('null discovery callback is a no-op', () async {
      final requests = <http.Request>[];
      final manager = makeManager(
        mockClient: createMockClient(onRequest: requests.add),
        dataDir: tempDir,
        discoverSpaces: null,
      );
      addTearDown(manager.dispose);

      await expectLater(manager.reconcile(), completes);

      expect(requests, isEmpty);
    });

    test('waits 200ms between discovered subscribe calls', () async {
      final delays = <Duration>[];
      final manager = makeManager(
        mockClient: createMockClient(),
        dataDir: tempDir,
        delay: (duration) async => delays.add(duration),
        discoverSpaces: () async => ['SPACE_A', 'SPACE_B', 'SPACE_C'],
      );
      addTearDown(manager.dispose);

      await expectLater(manager.reconcile(), completes);

      expect(delays.where((duration) => duration == const Duration(milliseconds: 200)), hasLength(2));
    });
  });

  group('persistence', () {
    test('persists after subscribe', () async {
      final manager = makeManager(mockClient: createMockClient(), dataDir: tempDir);
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');

      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      expect(file.existsSync(), isTrue);
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(json['subscriptions'], hasLength(1));
      expect(json['subscriptions'][0]['spaceId'], 'SPACE_1');
    });

    test('persists after unsubscribe', () async {
      final manager = makeManager(mockClient: createMockClient(), dataDir: tempDir);
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');
      await manager.unsubscribe('SPACE_1');

      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((json['subscriptions'] as List), isEmpty);
    });

    test('survives malformed JSON file on load', () async {
      final file = File('${tempDir.path}/google-chat-subscriptions.json');
      file.writeAsStringSync('not json!');

      final manager = makeManager(mockClient: createMockClient(), dataDir: tempDir);
      addTearDown(manager.dispose);

      // Should not throw
      await expectLater(manager.reconcile(), completes);
      expect(manager.subscriptions, isEmpty);
    });

    test('creates parent directory if missing', () async {
      final nestedDir = Directory('${tempDir.path}/nested/deeply');
      final manager = WorkspaceEventsManager(
        authClient: createMockClient(),
        config: testConfig(),
        dataDir: nestedDir.path,
        delay: (_) async {},
      );
      addTearDown(manager.dispose);

      await manager.subscribe('SPACE_1');

      final file = File('${nestedDir.path}/google-chat-subscriptions.json');
      expect(file.existsSync(), isTrue);
    });
  });

  group('dispose', () {
    test('isDisposed reflects state', () {
      final manager = makeManager(mockClient: createMockClient(), dataDir: tempDir);
      expect(manager.isDisposed, isFalse);
      manager.dispose();
      expect(manager.isDisposed, isTrue);
    });

    test('double dispose is safe', () {
      final manager = makeManager(mockClient: createMockClient(), dataDir: tempDir);
      manager.dispose();
      expect(() => manager.dispose(), returnsNormally);
    });
  });
}
