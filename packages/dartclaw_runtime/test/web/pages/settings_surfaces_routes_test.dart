import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/api/channel_access_service.dart';
import 'package:dartclaw_runtime/src/api/config_apply_service.dart';
import 'package:dartclaw_runtime/src/api/guard_editor_service.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/web/pages/settings_page.dart';
import 'package:dartclaw_runtime/src/web/settings/settings_surface.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';
import '../../whatsapp_test_support.dart';

const _configYaml = '''
port: 3000
host: localhost
channels:
  whatsapp:
    enabled: true
    dm_access: pairing
    dm_allowlist: []
  google_chat:
    enabled: true
    service_account: /tmp/google-service-account.json
    oauth_credentials: /tmp/google-oauth-client.json
    audience:
      type: app-url
      value: https://example.com/integrations/googlechat
    dm_access: open
    group_access: allowlist
    group_allowlist:
      - spaces/AAA
    require_mention: true
guards:
  command:
    extra_blocked_patterns:
      - dangerous-command
  file:
    extra_rules: []
  network:
    extra_allowed_domains:
      - example.com
''';

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;
  late SessionService sessions;
  late SettingsPage page;
  late PageContext context;
  late DmAccessController whatsAppAccess;
  late String pairingCode;

  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('settings_surfaces_routes_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    File(configPath).writeAsStringSync(_configYaml);
    sessions = SessionService(baseDir: tempDir.path);
    final writer = ConfigWriter(configPath: configPath);
    final surface = SettingsSurface(
      writer: writer,
      dataDir: dataDir,
      runtimeConfig: RuntimeConfig(heartbeatEnabled: false, gitSyncEnabled: false),
      applyService: ConfigApplyService(writer: writer, validator: const ConfigValidator(), dataDir: dataDir),
    );
    whatsAppAccess = DmAccessController(mode: DmAccessMode.pairing);
    pairingCode = whatsAppAccess.createPairing('15551234567@s.whatsapp.net', displayName: 'Alice')!.code;
    final whatsApp = WhatsAppChannel(
      gowa: FakeGowaManager(),
      config: const WhatsAppConfig(enabled: true, dmAccess: DmAccessMode.pairing),
      dmAccess: whatsAppAccess,
      mentionGating: MentionGating(requireMention: false, mentionPatterns: const [], ownJid: ''),
    );
    final googleChatAccess = DmAccessController(mode: DmAccessMode.pairing);
    final googleChat = GoogleChatChannel(
      config: const GoogleChatConfig(enabled: true, dmAccess: DmAccessMode.pairing),
      restClient: FakeGoogleChatRestClient(),
      dmAccess: googleChatAccess,
    );
    page = SettingsPage(
      whatsAppChannel: whatsApp,
      googleChatChannel: googleChat,
      settingsSurface: surface,
      channelAccessService: ChannelAccessService(
        writer: writer,
        dataDir: dataDir,
        whatsAppChannel: whatsApp,
        googleChatChannel: googleChat,
      ),
      guardEditorService: GuardEditorService(writer: writer, dataDir: dataDir),
    );
    context = PageContext(
      sessions: sessions,
      config: DartclawConfig.load(configPath: configPath),
      sidebarData: () async => _emptySidebarData,
      restartBannerHtml: () => '',
      buildNavItems: ({required String activePage}) => const [],
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('activating a mode writes once and returns the active card with restart state out of band', () async {
    final response = await page.handler(
      _formRequest('/settings/channels/google_chat/access', {'dm_access': 'allowlist'}),
      context,
    );
    final body = await response.readAsString();
    final dmGroup = body.substring(
      body.indexOf('aria-labelledby="dm-access-question"'),
      body.indexOf('id="channel-dm-access"'),
    );

    expect(response.statusCode, 200);
    expect(response.headers['HX-Trigger-After-Swap'], isNull);
    expect(RegExp(r'aria-checked="true"').allMatches(dmGroup).length, 1);
    expect(dmGroup, contains('value="allowlist"'));
    expect(body, contains('hx-swap-oob="true"'));
    expect(File(configPath).readAsStringSync(), contains('dm_access: allowlist'));
  });

  test('an invalid mode stays local to its control and leaves the config unchanged', () async {
    final before = File(configPath).readAsBytesSync();
    final response = await page.handler(
      _formRequest('/settings/channels/google_chat/access', {'dm_access': 'bogus'}),
      context,
    );
    final body = await response.readAsString();
    const message =
        "Field 'channels.google_chat.dm_access' must be one of: open, disabled, allowlist, pairing — got 'bogus'";
    final dmGroup = body.substring(
      body.indexOf('aria-labelledby="dm-access-question"'),
      body.indexOf('id="channel-dm-access"'),
    );

    expect(response.statusCode, 200);
    expect(dmGroup, contains('aria-invalid="true"'));
    expect(dmGroup, contains(message));
    expect(dmGroup, matches(RegExp(r'value="open"[^>]*aria-checked="true"')));
    expect(response.headers['HX-Trigger-After-Swap'], isNull);
    expect(File(configPath).readAsBytesSync(), before);
  });

  test('Google Chat service account values are masked on the owning detail surface', () async {
    const inlineJson =
        '{"type":"service_account","client_email":"chat-bot@example.iam.gserviceaccount.com","private_key":"secret"}';
    for (final value in ['/tmp/google-service-account.json', inlineJson]) {
      File(configPath).writeAsStringSync(
        _configYaml.replaceFirst('/tmp/google-service-account.json', value == inlineJson ? "'$inlineJson'" : value),
      );
      final response = await page.handler(
        Request('GET', Uri.parse('http://localhost/settings/channels/google_chat')),
        context,
      );
      final body = await response.readAsString();
      final fieldStart = body.indexOf('data-field="channels.google_chat.service_account"');
      final nextField = body.indexOf('data-field="', fieldStart + 1);
      final fieldHtml = body.substring(fieldStart, nextField);

      expect(response.statusCode, 200);
      expect(body, isNot(contains(value)));
      expect(body, isNot(contains('chat-bot@example.iam.gserviceaccount.com')));
      expect(fieldHtml, contains('Configured'));
      expect(fieldHtml, isNot(contains('<input')));
      expect(fieldHtml, isNot(contains('<select')));
      expect(fieldHtml, isNot(contains('<textarea')));
    }

    File(configPath)
        .writeAsStringSync(_configYaml.replaceFirst('    service_account: /tmp/google-service-account.json\n', ''));
    final absent = await page.handler(
      Request('GET', Uri.parse('http://localhost/settings/channels/google_chat')),
      context,
    );
    final absentBody = await absent.readAsString();
    final fieldStart = absentBody.indexOf('data-field="channels.google_chat.service_account"');
    final nextField = absentBody.indexOf('data-field="', fieldStart + 1);

    expect(absentBody.substring(fieldStart, nextField), contains('Not configured'));
  });

  test('Google Chat advanced submissions preserve configured and absent OAuth paths', () async {
    Future<String> renderedOauthValue() async {
      final response = await page.handler(
        Request('GET', Uri.parse('http://localhost/settings/channels/google_chat')),
        context,
      );
      final body = await response.readAsString();
      final field = body.substring(
        body.indexOf('data-field="channels.google_chat.oauth_credentials"'),
        body.indexOf('data-field="', body.indexOf('data-field="channels.google_chat.oauth_credentials"') + 1),
      );
      return RegExp(r'name="channels\.google_chat\.oauth_credentials"[^>]*value="([^"]*)"')
          .firstMatch(field)!
          .group(1)!;
    }

    final configuredValue = await renderedOauthValue();
    expect(configuredValue, '/tmp/google-oauth-client.json');
    await page.handler(
      _formRequest('/settings/channels/google_chat/fields', {
        'channels.google_chat.oauth_credentials': configuredValue,
        'channels.google_chat.webhook_path': '/chat-hook',
      }),
      context,
    );
    expect(File(configPath).readAsStringSync(), contains('oauth_credentials: /tmp/google-oauth-client.json'));

    File(configPath)
        .writeAsStringSync(_configYaml.replaceFirst('    oauth_credentials: /tmp/google-oauth-client.json\n', ''));
    final absentValue = await renderedOauthValue();
    expect(absentValue, isEmpty);
    await page.handler(
      _formRequest('/settings/channels/google_chat/fields', {
        'channels.google_chat.oauth_credentials': absentValue,
        'channels.google_chat.webhook_path': '/chat-hook',
      }),
      context,
    );
    expect(File(configPath).readAsStringSync(), isNot(contains('oauth_credentials:')));
  });

  test('a Google Chat access mutation re-renders the freshly committed YAML policy', () async {
    File(configPath).writeAsStringSync(_configYaml.replaceFirst('    dm_access: open', '    dm_access: pairing'));
    final response = await page.handler(
      _formRequest('/settings/channels/google_chat/access', {'dm_access': 'open'}),
      context,
    );
    final body = await response.readAsString();
    final dmGroup = body.substring(
      body.indexOf('aria-labelledby="dm-access-question"'),
      body.indexOf('id="channel-dm-access"'),
    );

    expect(dmGroup, matches(RegExp(r'value="open"[^>]*aria-checked="true"')));
    expect(body, isNot(contains('hx-trigger="every 5s"')));
    expect(File(configPath).readAsStringSync(), contains('dm_access: open'));
  });

  test('a duplicate group entry returns the shared conflict inline and writes nothing', () async {
    final before = File(configPath).readAsBytesSync();
    final response = await page.handler(
      _formRequest('/settings/channels/google_chat/group-allowlist/add', {'group_allowlist_entry': 'spaces/AAA'}),
      context,
    );
    final body = await response.readAsString();

    expect(response.statusCode, 200);
    expect(body, contains('Entry "spaces/AAA" already in group allowlist'));
    expect(body, contains('value="spaces/AAA"'));
    expect(File(configPath).readAsBytesSync(), before);
  });

  test('adding a DM entry returns the server-rendered row and updates the persisted count', () async {
    final response = await page.handler(
      _formRequest('/settings/channels/google_chat/dm-allowlist/add', {'dm_allowlist_entry': 'users/123456789'}),
      context,
    );
    final body = await response.readAsString();

    expect(response.statusCode, 200);
    expect(body, contains('allowlist-count-num">1</span>'));
    expect(body, contains('users/123456789'));
    expect(File(configPath).readAsStringSync(), contains('users/123456789'));
  });

  test('pairing poll and approval return the pairing fragment plus the DM allowlist out of band', () async {
    final poll = await page.handler(
      Request('GET', Uri.parse('http://localhost/settings/channels/whatsapp/pairings')),
      context,
    );
    final pollBody = await poll.readAsString();
    expect(pollBody, contains('hx-trigger="every 5s"'));
    expect(pollBody, contains('Alice'));

    final confirmed = await page.handler(
      _formRequest('/settings/channels/whatsapp/pairings/confirm', {'code': pairingCode}),
      context,
    );
    final body = await confirmed.readAsString();
    expect(body, isNot(contains('Alice')));
    expect(body, contains('hx-swap-oob="outerHTML:#dm-allowlist-fragment"'));
    expect(body, contains('15551234567@s.whatsapp.net'));
    expect(whatsAppAccess.allowlist, contains('15551234567@s.whatsapp.net'));
  });

  test('guard rules are in the first response and a stale delete is refused without a write', () async {
    final first = await page.handler(Request('GET', Uri.parse('http://localhost/settings')), context);
    expect(await first.readAsString(), contains('dangerous-command'));

    final before = File(configPath).readAsBytesSync();
    final refused = await page.handler(
      _formRequest('/settings/guards/command/extra_blocked_patterns/0/delete', {'display': 'different-command'}),
      context,
    );
    final body = await refused.readAsString();

    expect(refused.statusCode, 200);
    expect(body, contains('The rule changed since it was displayed'));
    expect(File(configPath).readAsBytesSync(), before);
  });

  test('guard editing keeps refused updates in the server-rendered dialog', () async {
    final dialog = await page.handler(
      Request('GET', Uri.parse('http://localhost/settings/guards/command/extra_blocked_patterns/0/edit')),
      context,
    );
    final dialogBody = await dialog.readAsString();
    expect(dialog.statusCode, 200);
    expect(dialogBody, contains('<dialog class="dialog'));
    expect(dialogBody, isNot(contains('<dialog open')));
    expect(dialogBody, contains('value="dangerous-command"'));
    expect(dialogBody, contains('hx-post="/settings/guards/command/extra_blocked_patterns/0/update"'));

    final before = File(configPath).readAsBytesSync();
    final stale = await page.handler(
      _formRequest('/settings/guards/command/extra_blocked_patterns/0/update', {
        'display': 'different-command',
        'value': 'replacement-command',
      }),
      context,
    );
    final staleBody = await stale.readAsString();
    expect(stale.headers['HX-Retarget'], '#guard-edit-dialog-host');
    expect(staleBody, contains('<dialog class="dialog'));
    expect(staleBody, contains('name="display" value="different-command"'));
    expect(staleBody, contains('value="replacement-command" aria-invalid="true"'));
    expect(staleBody, contains('<div class="form-error t-caption">The rule changed since it was displayed'));
    expect(File(configPath).readAsBytesSync(), before);

    final invalid = await page.handler(
      _formRequest('/settings/guards/command/extra_blocked_patterns/0/update', {
        'display': 'dangerous-command',
        'value': '',
      }),
      context,
    );
    final invalidBody = await invalid.readAsString();
    expect(invalid.headers['HX-Retarget'], '#guard-edit-dialog-host');
    expect(invalidBody, contains('<dialog class="dialog'));
    expect(invalidBody, contains('name="display" value="dangerous-command"'));
    expect(invalidBody, contains('value="" aria-invalid="true"'));
    expect(
      invalidBody,
      contains('<div class="form-error t-caption">command.extra_blocked_patterns: value is required'),
    );
    expect(File(configPath).readAsBytesSync(), before);

    final corrected = await page.handler(
      _formRequest('/settings/guards/command/extra_blocked_patterns/0/update', {
        'display': 'dangerous-command',
        'value': 'replacement-command',
      }),
      context,
    );
    final correctedBody = await corrected.readAsString();
    expect(corrected.headers['HX-Retarget'], isNull);
    expect(correctedBody, contains('id="guard-editor"'));
    expect(correctedBody, contains('replacement-command'));
    expect(File(configPath).readAsStringSync(), contains('replacement-command'));
  });

  test('oversized channel and guard forms preserve the canonical 413 envelope', () async {
    const expected = '{"error":{"code":"REQUEST_TOO_LARGE","message":"request body is too large"}}';
    for (final path in ['/settings/channels/google_chat/access', '/settings/guards/command/add']) {
      final response = await page.handler(_oversizedFormRequest(path), context);

      expect(response.statusCode, 413, reason: path);
      expect(await response.readAsString(), expected, reason: path);
    }
  });
}

Request _formRequest(String path, Map<String, String> fields) => withAdminAuthContext(
  Request(
    'POST',
    Uri.parse('http://localhost$path'),
    headers: const {'content-type': 'application/x-www-form-urlencoded'},
    body: fields.entries
        .map((entry) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
        .join('&'),
  ),
);

Request _oversizedFormRequest(String path) => withAdminAuthContext(
  Request(
    'POST',
    Uri.parse('http://localhost$path'),
    headers: const {'content-type': 'application/x-www-form-urlencoded'},
    body: 'value=${'x' * (128 * 1024)}',
  ),
);

final _emptySidebarData = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
  activeTasks: <SidebarActiveTask>[],
  activeWorkflows: <SidebarActiveWorkflow>[],
  showChannels: true,
  tasksEnabled: false,
  activeSessionId: null,
);
