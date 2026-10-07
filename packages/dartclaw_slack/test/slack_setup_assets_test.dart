import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _slashCommands = {'/stop', '/pause', '/resume', '/bind', '/unbind'};
const _botEvents = {'app_mention', 'message.im', 'message.channels', 'message.groups'};
const _slackKeyPrefix = 'channels.slack.';

void main() {
  late Uri root;
  late Map<String, dynamic> socket;
  late Map<String, dynamic> events;
  setUpAll(() async {
    final barrel = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_slack/dartclaw_slack.dart'));
    root = barrel!.resolve('../../../');
    socket = _readManifest(root, 'examples/slack/manifest-socket.yaml');
    events = _readManifest(root, 'examples/slack/manifest-events.yaml');
  });

  group('shipped manifests', () {
    test('both declare what the adapter subscribes to and the scopes doctor compares against', () {
      for (final manifest in [socket, events]) {
        expect(manifest['features']['assistant_view']['assistant_description'], isNotEmpty);
        expect(manifest['oauth_config']['scopes']['bot'], unorderedEquals(slackExpectedBotScopes));
        expect(manifest['settings']['event_subscriptions']['bot_events'], unorderedEquals(_botEvents));
        expect(manifest['settings']['interactivity']['is_enabled'], isTrue);
        expect(_slashCommandEntries(manifest).map((c) => c['command']), unorderedEquals(_slashCommands));
      }
      expect(slackExpectedBotScopes, hasLength(10));
    });

    test(
      'socket mode is on without a request URL; the events manifest turns it off and points every URL at the route',
      () {
        expect(socket['settings']['socket_mode_enabled'], isTrue);
        expect(_requestUrls(socket), isEmpty);

        final path = const SlackConfig().webhookPath;
        expect(events['settings']['socket_mode_enabled'], isFalse);
        final urls = _requestUrls(events);
        expect(urls, hasLength(2 + _slashCommands.length), reason: 'events, interactivity and one URL per command');
        expect(urls.every((url) => url.startsWith('https://') && url.endsWith(path)), isTrue, reason: '$urls');
      },
    );

    test('the two manifests differ in nothing but the transport switch and the request URLs', () {
      expect(_withoutTransport(socket), _withoutTransport(events));
    });
  });

  group('guide', () {
    late String guide;

    setUpAll(() => guide = File.fromUri(root.resolve('docs/guide/slack.md')).readAsStringSync());

    test('documents every channels.slack key with its type and default', () {
      final rows = _guideKeyRows(guide);
      final defaults = const SlackConfig();
      final keys = ConfigMeta.fields.keys.where((key) => key.startsWith(_slackKeyPrefix)).toList();
      expect(keys, isNotEmpty);

      for (final key in keys) {
        final meta = ConfigMeta.fields[key]!;
        final row = rows[key];
        expect(row, isNotNull, reason: 'docs/guide/slack.md has no table row for $key');
        expect(row![0], _typeWord(meta.type), reason: 'type of $key');
        expect(row[1], _defaultFor(key.substring(_slackKeyPrefix.length), defaults), reason: 'default of $key');
        for (final value in meta.allowedValues ?? const <String>[]) {
          expect(row[2], contains('`$value`'), reason: 'allowed value $value of $key');
        }
      }
      expect(rows.keys.toSet().difference(keys.toSet()), isEmpty, reason: 'guide rows for keys the schema lacks');
    });

    test('names the facts an owner needs to set up either transport', () {
      for (final needle in [
        'connections:write',
        'Basic Information',
        'slack.credentials',
        'slack.auth',
        'slack.scopes',
        'slack.transport',
        'examples/slack/manifest-socket.yaml',
        'examples/slack/manifest-events.yaml',
        const SlackConfig().webhookPath,
        'event ID',
        'reverse proxy',
        'Checked against docs.slack.dev on',
      ]) {
        expect(guide, contains(needle));
      }
    });
  });
}

Map<String, dynamic> _readManifest(Uri root, String path) =>
    jsonDecode(jsonEncode(loadYaml(File.fromUri(root.resolve(path)).readAsStringSync()))) as Map<String, dynamic>;

List<Map<String, dynamic>> _slashCommandEntries(Map<String, dynamic> manifest) =>
    (manifest['features']['slash_commands'] as List).cast<Map<String, dynamic>>();

List<String> _requestUrls(Map<String, dynamic> manifest) => [
  manifest['settings']['event_subscriptions']['request_url'],
  manifest['settings']['interactivity']['request_url'],
  for (final command in _slashCommandEntries(manifest)) command['url'],
].whereType<String>().toList();

Map<String, dynamic> _withoutTransport(Map<String, dynamic> manifest) {
  final copy = jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
  copy['settings'].remove('socket_mode_enabled');
  copy['settings']['event_subscriptions'].remove('request_url');
  copy['settings']['interactivity'].remove('request_url');
  for (final command in _slashCommandEntries(copy)) {
    command.remove('url');
  }
  return copy;
}

String _typeWord(ConfigFieldType type) => switch (type) {
  ConfigFieldType.string => 'string',
  ConfigFieldType.bool_ => 'boolean',
  ConfigFieldType.enum_ => 'enum',
  ConfigFieldType.stringList => 'list',
  _ => throw StateError('No guide type word for $type'),
};

String _defaultFor(String key, SlackConfig config) => switch (key) {
  'enabled' => '${config.enabled}',
  'mode' => config.mode,
  'bot_token_credential' => config.botTokenCredential ?? 'none',
  'app_token_credential' => config.appTokenCredential ?? 'none',
  'signing_secret_credential' => config.signingSecretCredential ?? 'none',
  'webhook_path' => config.webhookPath,
  'dm_access' => config.dmAccess.name,
  'dm_allowlist' => config.dmAllowlist.isEmpty ? 'empty' : throw StateError('non-empty default'),
  'group_access' => config.groupAccess.name,
  'group_allowlist' => config.groupAllowlist.isEmpty ? 'empty' : throw StateError('non-empty default'),
  'require_mention' => '${config.requireMention}',
  'mention_patterns' => config.mentionPatterns.isEmpty ? 'empty' : throw StateError('non-empty default'),
  'streaming' => '${config.streaming}',
  _ => throw StateError('No default declared for channels.slack.$key; add it here and to the guide'),
};

/// Rows of the guide's key table as `key -> [type, default, notes]`, backticks stripped from type and default.
Map<String, List<String>> _guideKeyRows(String guide) {
  final rows = <String, List<String>>{};
  for (final line in const LineSplitter().convert(guide)) {
    final cells = line.split('|').map((cell) => cell.trim()).toList();
    if (cells.length < 6 || !cells[1].startsWith('`$_slackKeyPrefix')) continue;
    rows[cells[1].replaceAll('`', '')] = [cells[2].replaceAll('`', ''), cells[3].replaceAll('`', ''), cells[4]];
  }
  return rows;
}
