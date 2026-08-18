import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/task_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart'
    show CodexRefreshAuthority, CredentialHealthMonitor, ProviderStatusService;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during task wiring test');

/// What the in-`serve` workflow one-shot lane says when its Codex spawn is
/// refused, and who hears it.
///
/// This lane spawns on the host, so no gateway sees the refusal: without its own
/// announcement the condition reaches the operator as a step failure and nothing
/// else — no alert, no provider card, no `/settings` change. The refusal is also
/// raised strictly before any process starts, so the resolver is the only place
/// it can be observed.
void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late SubscriptionCredentialStore store;
  late Map<String, String> operatorEnvironment;
  late TaskWiring taskWiring;

  /// Rebuilds the lane against the temp store so a test can vary only which
  /// providers are configured and which credentials exist.
  void wire({required ProvidersConfig providers, CredentialsConfig credentials = const CredentialsConfig.defaults()}) {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'codex'),
      providers: providers,
      credentials: credentials,
    );
    // Reopened rather than derived a second way: `data_dir` selects the store,
    // so a fixture naming its own path could pass against a directory this
    // wiring never reads. Reopening the same paths keeps anything already
    // written in place.
    store = SubscriptionCredentialStore.open(credentialsDir: config.credentialsDir, environment: operatorEnvironment);
    taskWiring = TaskWiring(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      // Never wired: the resolver under test reads only config, the store, and
      // the refresh authority, and refuses before any service is touched.
      storage: StorageWiring(
        config: config,
        eventBus: eventBus,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        exitFn: _unexpectedExit,
      ),
      executionInventory: ProviderExecutionInventory.of(
        providerIds: providers.entries.keys.toList(),
        acpProviderIds: const {},
      ),
      messageRedactor: MessageRedactor(),
      subscriptionCredentials: store.readAll,
      codexRefresh: CodexRefreshAuthority(
        store: store,
        // Either nothing is stored — so the refusal precedes the freshness gate
        // — or the stored token is far outside the near-expiry window. A
        // refresh reaching the vendor means the gate decided something else.
        vendorRefresh: (_) async => fail('a vendor refresh was driven for a credential that needed none'),
      ),
    );
  }

  /// Writes `auth.json` the way the vendor CLI does, with an expiry far outside
  /// the freshness gate's window so the stored token is presented unrotated.
  void storeCodexSubscription() {
    String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiry = DateTime.now().toUtc().add(const Duration(hours: 12));
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token':
              '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
              '.${segment({'exp': expiry.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}'
              '.c3Vic2NyaXB0aW9uLXRhc2s',
          'refresh_token': 'rt-must-never-be-read',
          'account_id': 'acct-task',
        },
        'last_refresh': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_wiring_codex_');
    eventBus = EventBus();
    operatorEnvironment = {
      'HOME': (Directory(p.join(tempDir.path, 'operator-home'))..createSync(recursive: true)).path,
    };
    wire(
      providers: ProvidersConfig(
        entries: {
          'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1, auth: ProviderAuth.subscription),
        },
      ),
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Prepares one workflow spawn's dedicated home for [providerId], whose
  /// resolved family is always Codex here.
  Future<String?> homeFor(String providerId) {
    final resolve = taskWiring.subscriptionHomeResolver;
    expect(resolve, isNotNull, reason: 'the workflow lane resolved no dedicated home for a Codex deployment');
    return resolve!(providerId, ProviderIdentity.codex);
  }

  /// Drives one workflow spawn's dedicated-home preparation and returns the
  /// refusal it raised.
  Future<Object> refusal() async {
    try {
      await homeFor(ProviderIdentity.codex);
    } catch (error) {
      return error;
    }
    fail('a forced subscription with nothing stored was admitted instead of refused');
  }

  test('the refusal names the store it searched', () async {
    // `dartclaw auth codex` writes to the store `data_dir` selects, so an
    // operator told only to re-authenticate can renew into a directory this
    // instance never reads — and re-run a command that already succeeded.
    expect(
      '${await refusal()}',
      allOf(contains(config.credentialsDir), contains('dartclaw auth')),
      reason: 'the workflow lane refused without naming the credential store it searched',
    );
  });

  test('the refusal announces credential health, which no gateway reaches on this lane', () async {
    final events = <CredentialHealthChangedEvent>[];
    final subscription = eventBus.on<CredentialHealthChangedEvent>().listen(events.add);
    addTearDown(subscription.cancel);
    // The real single writer over the ProviderStatusService the API reads,
    // bound the way `serve` binds it: several wiring steps after this class,
    // and still long before any workflow step spawns.
    final providerStatus = ProviderStatusService(
      providers: config.providers,
      registry: CredentialRegistry(credentials: const CredentialsConfig()),
      defaultProvider: 'codex',
    );
    taskWiring.credentialHealth = CredentialHealthMonitor(
      eventBus: eventBus,
      providerStatus: providerStatus,
      credentialsDir: config.credentialsDir,
      resolveCredentials: () => const {},
    );

    await refusal();
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single.providerId, 'codex');
    expect(events.single.state, CredentialHealthState.reauthRequired);
    expect(events.single.remediation, contains('dartclaw auth codex'));
    // The provider card must move with the alert, or /settings keeps reporting
    // a provider whose every workflow step refuses as healthy.
    final status = providerStatus.all.firstWhere((entry) => entry.id == 'codex').toJson();
    expect(status['credentialHealth'], 'reauth-required');
  });

  test('with no monitor bound yet the refusal still reaches the operator log', () async {
    // Nothing binds the monitor until step 8 of `serve` wiring, and a lane that
    // refuses before then must not go silent.
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() {
      subscription.cancel();
      Logger.root.level = previousLevel;
    });

    await refusal();

    expect(
      records.where((record) => record.level >= Level.SEVERE && record.message.contains(config.credentialsDir)),
      isNotEmpty,
      reason: 'an unbound monitor dropped the refusal instead of degrading to a severe line',
    );
  });

  group("an alias' own providers.<id>.auth decides its dedicated home", () {
    // A configured API key, so the alias' `api_key` selection is satisfiable
    // and the answer below is a decision rather than a failure to resolve.
    const openAiKey = CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'sk-alias')});

    void wireAlias(ProviderAuth? aliasAuth) {
      storeCodexSubscription();
      wire(
        providers: ProvidersConfig(
          entries: {
            'codex': ProviderEntry(
              executable: Platform.resolvedExecutable,
              poolSize: 1,
              auth: ProviderAuth.subscription,
            ),
            'my_codex': ProviderEntry(executable: 'codex', auth: aliasAuth),
          },
        ),
        credentials: openAiKey,
      );
    }

    test('an explicit api_key alias gets no dedicated home while its family still does', () async {
      wireAlias(ProviderAuth.apiKey);

      // Both spawns resolve the same family, so a family-keyed decision would
      // hand the alias the subscription store its own `auth` opted out of.
      expect(await homeFor('my_codex'), isNull);
      expect(await homeFor(ProviderIdentity.codex), store.codexHome);
    });

    test('an alias configuring no auth inherits its family and gets the home', () async {
      wireAlias(null);

      expect(
        await homeFor('my_codex'),
        store.codexHome,
        reason: 'an unset alias auth stopped inheriting the family selection',
      );
    });
  });
}
