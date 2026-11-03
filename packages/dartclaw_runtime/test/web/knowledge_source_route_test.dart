import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/auth/session_token.dart' show createSessionToken, sessionTtl;
import 'package:dartclaw_runtime/src/auth/source_link_token.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTemporalKnowledgeGraphService;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late KvService kvService;
  late SessionService sessions;
  late MessageService messages;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_source_route_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
  });

  tearDown(() async {
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('GET /knowledge/source', () {
    final key = 'a' * 64;
    late InMemoryTemporalKnowledgeGraphService kg;

    setUp(() {
      kg = InMemoryTemporalKnowledgeGraphService();
      File('${tempDir.path}/workspace/wiki/onboarding.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# Onboarding\n\nShared `team` knowledge.');
    });

    Router sourceRouter({
      String? gatewayToken,
      String authMode = 'token',
      EventBus? eventBus,
      AuthRateLimiter? rateLimiter,
    }) => webRoutes(
      sessions,
      messages,
      kvService: kvService,
      kgService: kg,
      gatewayToken: gatewayToken,
      eventBus: eventBus,
      rateLimiter: rateLimiter,
      config: DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        gateway: GatewayConfig(authMode: authMode),
      ),
      dataDir: tempDir.path,
    );

    /// The route behind the real auth middleware, so a request with no credential proves the exemption.
    Handler sourceHandler({
      String? gatewayToken,
      String authMode = 'token',
      EventBus? eventBus,
      AuthRateLimiter? rateLimiter,
    }) {
      final router = sourceRouter(
        gatewayToken: gatewayToken,
        authMode: authMode,
        eventBus: eventBus,
        rateLimiter: rateLimiter,
      );
      if (authMode == 'none') return router.call;
      return const Pipeline()
          .addMiddleware(
            authMiddleware(
              tokenService: TokenService(token: gatewayToken!),
              gatewayToken: gatewayToken,
            ),
          )
          .addHandler(router.call);
    }

    String wikiToken(String locator, {String? signedWith = 'a', DateTime? now}) => createSourceLinkToken(
      layer: 'wiki',
      locator: locator,
      key: signedWith == null ? null : signedWith * 64,
      now: now,
    );

    Request get(String? token) =>
        Request('GET', Uri.parse('http://localhost/knowledge/source${token == null ? '' : '?t=$token'}'));

    Request wikiViewGet(String locator) => Request('GET', Uri.parse('http://localhost/knowledge/wiki/$locator'));

    test('a link opens the cited wiki page read-only with no session and sets no cookie', () async {
      final res = await sourceHandler(gatewayToken: key)(get(wikiToken('wiki/onboarding.md')));
      final body = await res.readAsString();

      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/html'));
      expect(res.headers.keys.map((name) => name.toLowerCase()), isNot(contains('set-cookie')));
      expect(body, contains('data-markdown'));
      expect(body, contains('# Onboarding'));
      expect(body, contains('Shared `team` knowledge.'));
      expect(body, contains('onboarding.md'));
      expect(body, isNot(contains('class="sidebar"')));
      expect(body, isNot(contains('id="topbar"')));
      expect(body, isNot(contains('<div class="shell"')));
      expect(body, isNot(contains('restart-banner')));
    });

    test('hostile markdown stays escaped text inside the data-markdown container', () async {
      File('${tempDir.path}/workspace/wiki/evil.md').writeAsStringSync('<script>alert(1)</script>');

      final res = await sourceHandler(gatewayToken: key)(get(wikiToken('wiki/evil.md')));
      final body = await res.readAsString();
      final start = body.indexOf('data-markdown');
      final container = body.substring(start, body.indexOf('</div>', start));

      expect(container, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      expect(container, isNot(contains('<script')));
    });

    test('a link opens the cited graph fact and never shows its private source', () async {
      final id = await kg.addFact(
        entity: 'Billing service',
        predicate: 'owned by',
        value: 'Payments team',
        validFrom: '2026-01-01T00:00:00Z',
        validTo: '2026-12-31T00:00:00Z',
        source: 'PRIVATE-SOURCE-MARKER /home/operator/notes.md',
      );
      final token = createSourceLinkToken(layer: 'kg', locator: '$id', key: key);

      final res = await sourceHandler(gatewayToken: key)(get(token));
      final body = await res.readAsString();

      final stored = (await kg.factById(id))!;
      expect(res.statusCode, 200);
      expect(body, allOf(contains(stored.entity), contains(stored.predicate), contains(stored.value)));
      expect(body, allOf(contains(stored.validFrom), contains(stored.validTo!)));
      expect(body, isNot(contains('PRIVATE-SOURCE-MARKER')));
      expect(body, isNot(contains('/home/operator')));
      expect(body, isNot(contains('<div class="shell"')));
    });

    test('a fact with no end date reads as ongoing and an invalidated one says so', () async {
      final open = await kg.addFact(
        entity: 'Cache',
        predicate: 'ttl',
        value: '5m',
        validFrom: '2026-01-01T00:00:00Z',
        source: 's',
      );
      final closed = await kg.addFact(
        entity: 'Cache',
        predicate: 'ttl',
        value: '1m',
        validFrom: '2026-01-01T00:00:00Z',
        source: 's',
      );
      await kg.invalidate(id: closed, invalidatedAt: '2026-03-01T00:00:00Z', reason: 'PRIVATE-REASON');
      final handler = sourceHandler(gatewayToken: key);

      final openBody = await (await handler(get(createSourceLinkToken(layer: 'kg', locator: '$open', key: key))))
          .readAsString();
      final closedBody = await (await handler(get(createSourceLinkToken(layer: 'kg', locator: '$closed', key: key))))
          .readAsString();

      expect(openBody, contains('ongoing'));
      expect(openBody, isNot(contains('Invalidated')));
      expect(closedBody, contains('Invalidated'));
      expect(closedBody, contains((await kg.factById(closed))!.invalidatedAt!));
      expect(closedBody, isNot(contains('PRIVATE-REASON')));
    });

    test('every refusal is the same 404 as the wiki view\'s not-found', () async {
      final id = await kg.addFact(
        entity: 'e',
        predicate: 'p',
        value: 'v',
        validFrom: '2026-01-01T00:00:00Z',
        source: 's',
      );
      File('${tempDir.path}/workspace/wiki/gone.md').writeAsStringSync('soon deleted');
      final valid = wikiToken('wiki/onboarding.md');
      final parts = valid.split('.');
      final goneToken = wikiToken('wiki/gone.md');
      File('${tempDir.path}/workspace/wiki/gone.md').deleteSync();
      final handler = sourceHandler(gatewayToken: key);

      final refusals = <String, Request>{
        'altered signature': get('${parts[0]}.${parts[1].substring(1)}'),
        'altered locator': get('${wikiToken('wiki/secret.md').split('.').first}.${parts[1]}'),
        'expired': get(
          wikiToken('wiki/onboarding.md', now: DateTime.now().subtract(sessionTtl + const Duration(days: 1))),
        ),
        'deleted page': get(goneToken),
        'removed fact': get(createSourceLinkToken(layer: 'kg', locator: '${id + 100}', key: key)),
        'no token': get(null),
        'rotated gateway token': get(wikiToken('wiki/onboarding.md', signedWith: 'b')),
        'session cookie': get(createSessionToken(key)),
        'unknown layer': get(createSourceLinkToken(layer: 'memory', locator: 'entry-1', key: key)),
        'locator outside the wiki root': get(wikiToken('wiki/../secret.md')),
      };
      final reference = await sourceRouter(gatewayToken: key).call(wikiViewGet('wiki/absent.md'));
      final referenceBody = await reference.readAsString();

      expect(reference.statusCode, 404);
      for (final entry in refusals.entries) {
        final res = await handler(entry.value);
        expect(res.statusCode, reference.statusCode, reason: entry.key);
        expect(res.headers['content-type'], reference.headers['content-type'], reason: entry.key);
        expect(await res.readAsString(), referenceBody, reason: entry.key);
        expect(res.headers.keys.map((name) => name.toLowerCase()), isNot(contains('set-cookie')), reason: entry.key);
      }
    });

    group('failed authentication', () {
      late EventBus eventBus;
      late List<FailedAuthEvent> failures;

      setUp(() {
        eventBus = EventBus();
        failures = [];
        final subscription = eventBus.on<FailedAuthEvent>().listen(failures.add);
        addTearDown(() async {
          await subscription.cancel();
          await eventBus.dispose();
        });
      });

      test('a forged token fires one failed-auth event and still answers the one 404', () async {
        final res = await sourceHandler(gatewayToken: key, eventBus: eventBus)(
          get(wikiToken('wiki/onboarding.md', signedWith: 'b')),
        );
        await pumpEventQueue();

        expect(res.statusCode, 404);
        expect(failures, hasLength(1));
        expect(
          (failures.single.source, failures.single.path, failures.single.reason, failures.single.limited),
          ('source_link', '/knowledge/source', 'invalid_source_token', false),
        );
      });

      test('a request with no token is a failed authentication too', () async {
        await sourceHandler(gatewayToken: key, eventBus: eventBus)(get(null));
        await pumpEventQueue();

        expect(failures.single.reason, 'missing_source_token');
      });

      test('a valid link, and a valid link whose page is gone, fire nothing', () async {
        final goneToken = wikiToken('wiki/gone.md');
        final handler = sourceHandler(gatewayToken: key, eventBus: eventBus);

        final open = await handler(get(wikiToken('wiki/onboarding.md')));
        final gone = await handler(get(goneToken));
        await pumpEventQueue();

        expect((open.statusCode, gone.statusCode), (200, 404));
        expect(failures, isEmpty, reason: 'a signed link is not a failed credential, whatever it points at');
      });

      test(
        'failures share the limiter: past its budget a forged token answers 429, a valid link still opens',
        () async {
          final limiter = AuthRateLimiter(maxAttempts: 2);
          final handler = sourceHandler(gatewayToken: key, eventBus: eventBus, rateLimiter: limiter);
          final forged = get(wikiToken('wiki/onboarding.md', signedWith: 'b'));

          final statuses = [for (var i = 0; i < 4; i++) (await handler(forged)).statusCode];
          final open = await handler(get(wikiToken('wiki/onboarding.md')));
          await pumpEventQueue();

          expect(statuses, [404, 404, 429, 429]);
          expect(open.statusCode, 200);
          expect(failures.map((event) => event.limited), [false, false, true, true]);
          expect(limiter.shouldLimit('unknown'), isTrue, reason: 'a valid link does not reset the shared window');
        },
      );
    });

    test('the standalone page carries no command palette and no shell or HTMX scripts', () async {
      final handler = sourceHandler(gatewayToken: key);
      final wiki = await (await handler(get(wikiToken('wiki/onboarding.md')))).readAsString();
      final id = await kg.addFact(
        entity: 'e',
        predicate: 'p',
        value: 'v',
        validFrom: '2026-01-01T00:00:00Z',
        source: 's',
      );
      final fact = await (await handler(get(createSourceLinkToken(layer: 'kg', locator: '$id', key: key))))
          .readAsString();

      for (final page in [wiki, fact]) {
        expect(page, isNot(contains('global-command-dialog')));
        expect(page, isNot(contains('data-controller')));
        expect(page, isNot(contains('/controllers/index.js')));
        expect(page, isNot(contains('stimulus.min.js')));
        expect(page, isNot(contains('htmx.min.js')));
        expect(page, isNot(contains('sse.js')));
        expect(page, contains('/source_view.js'));
      }
      expect(wiki, allOf(contains('marked.min.js'), contains('purify.min.js')));
    });

    test('only the exact path is auth-exempt, so a sibling path still needs a session', () async {
      final res = await sourceHandler(gatewayToken: key)(
        Request('GET', Uri.parse('http://localhost/knowledge/source/extra?t=${wikiToken('wiki/onboarding.md')}')),
      );

      expect(res.statusCode, 401);
    });

    test('under auth_mode none a link carries no signature and opens, outside the wiki root still 404s', () async {
      final handler = sourceHandler(authMode: 'none');
      final open = await handler(get(wikiToken('wiki/onboarding.md', signedWith: null)));
      final outside = await handler(get(wikiToken('wiki/../secret.md', signedWith: null)));

      expect(wikiToken('wiki/onboarding.md', signedWith: null), isNot(contains('.')));
      expect(open.statusCode, 200);
      expect(await open.readAsString(), contains('Shared `team` knowledge.'));
      expect(outside.statusCode, 404);
      expect(await outside.readAsString(), contains('Wiki source not found'));
    });

    test('a signed token is no credential under auth_mode none and a missing key refuses every link', () async {
      expect((await sourceHandler(authMode: 'none')(get(wikiToken('wiki/onboarding.md')))).statusCode, 404);
      final keyless = webRoutes(
        sessions,
        messages,
        kvService: kvService,
        config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
      ).call;
      expect((await keyless(get(wikiToken('wiki/onboarding.md', signedWith: null)))).statusCode, 404);
    });
  });
}
