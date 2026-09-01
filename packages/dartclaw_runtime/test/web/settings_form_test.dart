import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/api/config_apply_service.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/web/pages/settings_page.dart';
import 'package:dartclaw_runtime/src/web/settings/settings_field_view.dart';
import 'package:dartclaw_runtime/src/web/settings/settings_form_model.dart';
import 'package:dartclaw_runtime/src/web/settings/settings_sections.dart';
import 'package:dartclaw_runtime/src/web/settings/settings_surface.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

const _baseYaml = '''
port: 8181
host: 0.0.0.0
agent:
  provider: claude
  model: opus
  effort: high
scheduling:
  heartbeat:
    enabled: false
    interval_minutes: 30
gateway:
  token: super-secret-gateway-token
credentials:
  anthropic:
    api_key: sk-ant-super-secret
''';

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;
  late SessionService sessions;

  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('settings_form_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    File(configPath).writeAsStringSync(_baseYaml);
    sessions = SessionService(baseDir: tempDir.path);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  SettingsSurface buildSurface({EventBus? eventBus, ConfigNotifier? notifier}) {
    final writer = ConfigWriter(configPath: configPath);
    return SettingsSurface(
      writer: writer,
      dataDir: dataDir,
      runtimeConfig: RuntimeConfig(heartbeatEnabled: false, gitSyncEnabled: false),
      applyService: ConfigApplyService(
        writer: writer,
        validator: const ConfigValidator(),
        dataDir: dataDir,
        eventBus: eventBus,
        configNotifier: notifier,
      ),
    );
  }

  Future<String> renderPage(SettingsSurface surface) async {
    final response = await SettingsPage(settingsSurface: surface)
        .handler(Request('GET', Uri.parse('http://localhost/settings')), _pageContext(sessions));
    return response.readAsString();
  }

  Future<Response> post(SettingsSurface surface, Map<String, String> body) {
    final registry = PageRegistry()..register(SettingsPage(settingsSurface: surface));
    final handler = webRoutes(sessions, MessageService(baseDir: tempDir.path), pageRegistry: registry).call;
    return Future.value(
      handler(
        withAdminAuthContext(
          Request(
            'POST',
            Uri.parse('http://localhost/settings'),
            body: body.entries
                .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
                .join('&'),
            headers: const {'content-type': 'application/x-www-form-urlencoded'},
          ),
        ),
      ),
    );
  }

  group('POST /settings resolves its surface from the registered page alone', () {
    // `webRoutes` used to build a second surface of its own from `configWriter`
    // / `configNotifier`, which no caller ever passed — so the fallback behind
    // it was unreachable. The registered page is the only source.
    Future<Response> postTo(PageRegistry registry) {
      final handler = webRoutes(sessions, MessageService(baseDir: tempDir.path), pageRegistry: registry).call;
      return handler(
        withAdminAuthContext(
          Request(
            'POST',
            Uri.parse('http://localhost/settings'),
            body: '$settingsSectionFormField=agent',
            headers: {'content-type': 'application/x-www-form-urlencoded'},
          ),
        ),
      );
    }

    test('a settings page registered without a surface answers read-only', () async {
      final response = await postTo(PageRegistry()..register(SettingsPage()));

      expect(response.statusCode, 404);
      expect(await response.readAsString(), contains('Settings editing is not available on this server'));
    });

    test('no settings page at all answers read-only too', () async {
      final response = await postTo(PageRegistry());

      expect(response.statusCode, 404);
      expect(await response.readAsString(), contains('Settings editing is not available on this server'));
    });

    test('a settings page registered with a surface accepts the save', () async {
      final response = await postTo(PageRegistry()..register(SettingsPage(settingsSurface: buildSurface())));

      expect(response.statusCode, 200);
    });
  });

  group('registry coverage', () {
    test('every registered field resolves to exactly one panel or one named owner', () {
      final unassigned = <String>[];
      final ownedElsewhere = <String>{};
      for (final path in ConfigMeta.fields.keys) {
        final panel = settingsPanelForField(path);
        final owner = settingsFieldOwnerFor(path);
        if (panel != null) continue;
        if (owner != null) {
          ownedElsewhere.add(path);
          continue;
        }
        unassigned.add(path);
      }

      expect(unassigned, isEmpty, reason: 'these registered fields reach no settings surface at all');
      // Exact set comparison, not a "does not contain" check: a partial
      // migration would otherwise pass while silently dropping fields.
      expect(
        ownedElsewhere,
        ConfigMeta.fields.keys
            .where((path) => path == 'channels' || path.startsWith('channels.') || path.startsWith('guards.'))
            .toSet(),
      );
      expect(settingsFieldOwners.keys.toSet(), {'channels', 'guards'});
    });

    test('no two panels declare an overlapping prefix, and every id is unique', () {
      // Read off the declarations, not off the resolver under test: the
      // resolver answers exactly one panel by construction, so deriving the
      // claim map from it could never report a contest.
      final declared = <String, String>{};
      final contested = <String>[];
      for (final panel in settingsPanels) {
        for (final prefix in panel.prefixes) {
          for (final entry in declared.entries) {
            final a = entry.key;
            if (a == prefix || a.startsWith('$prefix.') || prefix.startsWith('$a.')) {
              contested.add('${panel.id}:$prefix overlaps ${entry.value}:$a');
            }
          }
          for (final owner in settingsFieldOwners.keys) {
            if (prefix == owner || prefix.startsWith('$owner.')) {
              contested.add('${panel.id}:$prefix is inside the owned-elsewhere prefix $owner');
            }
          }
          declared[prefix] = panel.id;
        }
      }

      expect(contested, isEmpty);
      expect(settingsPanels.map((panel) => panel.id).toSet(), hasLength(settingsPanels.length));
      expect(settingsTabs.map((tab) => tab.id).toSet(), hasLength(settingsTabs.length));
      // Every panel hangs off a declared tab, so no aria-controls list is orphaned.
      final tabIds = settingsTabs.map((tab) => tab.id).toSet();
      expect(settingsPanels.where((panel) => !tabIds.contains(panel.tab)), isEmpty);
    });

    test('a persisted value outside allowedValues keeps its own selected row', () {
      final meta = ConfigMeta.fields['governance.queue_strategy']!;
      expect(meta.nullable, isFalse, reason: 'the fixture must not get a blank row for free');
      expect(meta.allowedValues, isNot(contains('retired-mode')));

      final view = SettingsFieldView(
        meta: meta,
        resolved: const ResolvedFieldValue(value: 'retired-mode', isSet: true),
      ).toTemplateMap();
      final options = (view['options']! as List).cast<Map<String, Object?>>();
      final selected = options.where((o) => o['selected'] == true).toList();

      // Matching no option leaves a browser preselecting the first, so an
      // untouched save would silently replace what the operator wrote.
      expect(selected, hasLength(1));
      expect(selected.single['value'], 'retired-mode');
      expect(options.first['value'], 'retired-mode');
      expect(options.map((o) => o['value']), containsAll(meta.allowedValues!));
    });

    test('a recognized value selects its own row and adds none', () {
      final meta = ConfigMeta.fields['governance.queue_strategy']!;
      final view = SettingsFieldView(
        meta: meta,
        resolved: const ResolvedFieldValue(value: 'fair', isSet: true),
      ).toTemplateMap();
      final options = (view['options']! as List).cast<Map<String, Object?>>();

      expect(options.map((o) => o['value']), meta.allowedValues);
      expect(options.where((o) => o['selected'] == true).single['value'], 'fair');
    });

    test('a fractional field renders a number input a browser will accept', () {
      final fractional = ConfigMeta.fields.values.where((f) => f.type == ConfigFieldType.double_).toList();
      expect(fractional, isNotEmpty, reason: 'the registry declares no double_ field, so this guard proves nothing');

      for (final meta in fractional) {
        final view = SettingsFieldView(meta: meta, resolved: ResolvedFieldValue.absent).toTemplateMap();
        expect(view['isNumber'], isTrue, reason: '${meta.yamlPath} must render as a number control');
        // Absent, an input[type=number] steps by 1 and a browser rejects 0.2.
        expect(view['step'], 'any', reason: '${meta.yamlPath} would refuse its own default in a browser');
      }

      final integral = ConfigMeta.fields.values.firstWhere((f) => f.type == ConfigFieldType.int_);
      final integralView = SettingsFieldView(meta: integral, resolved: ResolvedFieldValue.absent).toTemplateMap();
      expect(integralView['step'], isNull, reason: 'an integer field must keep the default step of 1');
    });

    test('a value-bearing field whose path names a secret is masked or valueless', () {
      final secretish = RegExp(r'(^|[._])(token|secret|api_key|apikey|password|credential)s?([._]|$)');
      final leaking = [
        for (final field in ConfigMeta.fields.values)
          if (secretish.hasMatch(field.yamlPath) &&
              field.type != ConfigFieldType.int_ &&
              field.type != ConfigFieldType.double_ &&
              field.type != ConfigFieldType.bool_ &&
              settingsPanelForField(field.yamlPath) != null &&
              !settingsMaskedFields.contains(field.yamlPath) &&
              controlKindFor(field) != SettingsControlKind.entries)
            field.yamlPath,
      ];

      // A numeric or boolean field cannot hold secret material — `*_tokens` there
      // is a budget, not a credential — so only value-bearing text is judged.
      // Both numeric types are exempt; a new one must be added here deliberately. The
      // form grows with the registry, so a newly registered secret must not become
      // an editable control printing its plaintext into `value="…"`.
      expect(leaking, isEmpty, reason: 'add these to settingsMaskedFields or give them a non-value control');
    });
  });

  group('field rendering', () {
    test('an enum field renders a select whose options are exactly its allowed values', () async {
      final html = await renderPage(buildSurface());
      final meta = ConfigMeta.fields['sessions.dm_scope']!;
      final group = _fieldGroup(html, 'sessions.dm_scope');

      expect(group, contains('<select'));
      final rendered = RegExp('<option[^>]*value="([^"]*)"').allMatches(group).map((m) => m.group(1)).toList();
      expect(rendered.where((value) => value!.isNotEmpty), meta.allowedValues);
    });

    test('an int field carries its declared range and the numeric width cap', () async {
      final html = await renderPage(buildSurface());
      final meta = ConfigMeta.fields['context.warning_threshold']!;
      final group = _fieldGroup(html, 'context.warning_threshold');

      expect(group, contains('type="number"'));
      expect(group, contains('min="${meta.min}"'));
      expect(group, contains('max="${meta.max}"'));
      expect(group, contains('form-input--num'));
    });

    test('a readonly field renders as a fact with no enabled control', () async {
      final html = await renderPage(buildSurface());
      final group = _fieldGroup(html, 'tasks.execution');

      expect(ConfigMeta.fields['tasks.execution']!.mutability, ConfigMutability.readonly);
      expect(group, isNot(contains('<input')));
      expect(group, isNot(contains('<select')));
      expect(group, isNot(contains('<textarea')));
      expect(group, contains('read-only'));
    });

    test('an object field renders the entry field names its shape declares', () async {
      final html = await renderPage(buildSurface());
      // The expectation comes from the registry entry itself, so nothing here
      // hard-codes what one provider entry may contain.
      final entry = ConfigMeta.fields['providers']!.entry as ObjectEntry;
      final group = _fieldGroup(html, 'providers');

      expect(entry.fields, isNotEmpty);
      for (final name in entry.fields.keys) {
        expect(group, contains('<code>$name</code>'), reason: 'entry key $name is not shown');
      }
      expect(group, isNot(contains('<input')));
    });

    test('every field a panel claims resolves to a value or an explicit unset', () {
      final writer = ConfigWriter(configPath: configPath);
      final resolver = SettingsValueResolver(
        serialized: const ConfigSerializer().toJson(
          DartclawConfig.load(configPath: configPath),
          runtime: RuntimeConfig(heartbeatEnabled: false, gitSyncEnabled: false),
        ),
        yaml: writer.readDocument(),
      );
      for (final panel in settingsPanels.where((panel) => panel.isForm)) {
        for (final field in settingsFieldsForPanel(panel)) {
          expect(() => resolver.resolve(field), returnsNormally, reason: field.yamlPath);
        }
      }
    });

    test('no credential or gateway token value reaches the page bytes', () async {
      final html = await renderPage(buildSurface());

      expect(html, isNot(contains('super-secret-gateway-token')));
      expect(html, isNot(contains('sk-ant-super-secret')));
      expect(_fieldGroup(html, 'gateway.token'), contains('Configured'));
      expect(_fieldGroup(html, 'credentials'), contains('Configured'));
    });
  });

  group('page rendering', () {
    test('a field no one hand-wrote markup for is on the page with its description as hint text', () async {
      final html = await renderPage(buildSurface());
      final templateSource = File(p.join(await resolveTemplatesDir(), 'settings.html')).readAsStringSync();

      for (final path in ['tasks.artifact_retention_days', 'knowledge.inbox.delivery_mode']) {
        expect(templateSource, isNot(contains(path)));
        final group = _fieldGroup(html, path);
        expect(group, contains(ConfigMeta.fields[path]!.description.split('.').first));
      }
      // The page template hand-authors no per-field markup at all.
      expect(templateSource, isNot(contains('data-field=')));
    });

    test('every in-scope registered field renders a data-field group', () async {
      final html = await renderPage(buildSurface());
      final rendered = RegExp('data-field="([^"]*)"').allMatches(html).map((m) => m.group(1)!).toSet();
      final expected = {
        for (final panel in settingsPanels.where((panel) => panel.isForm))
          for (final field in settingsFieldsForPanel(panel)) field.yamlPath,
        ...guardRegistryFields().map((field) => field.yamlPath),
      };

      expect(rendered, expected);
    });

    test('the first response already carries the persisted values, with no skeleton and no config fetch', () async {
      final html = await renderPage(buildSurface());

      expect(_fieldGroup(html, 'port'), contains('value="8181"'));
      expect(_fieldGroup(html, 'agent.model'), contains('value="opus"'));
      // No control is behind a placeholder that a client fetch would have to
      // resolve; the guard editor's own table skeleton is S60's surface.
      expect(html, isNot(contains('data-field-skeleton')));
      for (final form in RegExp(r'<form class="settings-form"[\s\S]*?</form>').allMatches(html)) {
        expect(form.group(0), isNot(contains('skeleton')));
      }
    });
  });

  group('saving a section', () {
    test('a restart-tier change writes YAML, badges the field and arms the shared banner', () async {
      final response = await post(buildSurface(), {
        settingsSectionFormField: 'agent',
        'agent.provider': 'claude',
        'agent.model': 'sonnet',
        'agent.effort': 'high',
      });
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(ConfigMeta.fields['agent.model']!.mutability, ConfigMutability.restart);
      expect(File(configPath).readAsStringSync(), contains('model: sonnet'));
      expect(File(p.join(dataDir, 'restart.pending')).readAsStringSync(), contains('agent.model'));
      expect(_fieldGroup(body, 'agent.model'), contains('restart required'));
      // The shell's banner rides the same response rather than a second fetch.
      expect(body, contains('id="restart-banner"'));
      expect(body, contains('hx-swap-oob="true"'));
      expect(body, contains('agent.model'));
    });

    test('a live-tier change takes effect on save with nothing left pending', () async {
      final bus = EventBus();
      final fired = <ConfigChangedEvent>[];
      bus.on<ConfigChangedEvent>().listen(fired.add);
      final response = await post(buildSurface(eventBus: bus), {
        settingsSectionFormField: 'scheduling',
        'scheduling.heartbeat.enabled': 'true',
        'scheduling.heartbeat.interval_minutes': '30',
      });
      final body = await response.readAsString();
      await Future<void>.delayed(Duration.zero);

      expect(response.statusCode, 200);
      expect(ConfigMeta.fields['scheduling.heartbeat.enabled']!.mutability, ConfigMutability.live);
      expect(fired.single.changedKeys, ['scheduling.heartbeat.enabled']);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), isFalse);
      expect(_fieldGroup(body, 'scheduling.heartbeat.enabled'), contains('applied'));
    });

    test('an out-of-range value is refused on its own control and nothing is written', () async {
      final before = File(configPath).readAsStringSync();
      final response = await post(buildSurface(), {
        settingsSectionFormField: 'server-config',
        'port': '0',
        'host': '127.0.0.1',
      });
      final body = await response.readAsString();
      final group = _fieldGroup(body, 'port');

      expect(response.statusCode, 200);
      expect(group, contains('aria-invalid="true"'));
      expect(group, contains('form-error'));
      expect(group, contains('must be between'));
      // The other edited field in the same submission is unwritten too.
      expect(File(configPath).readAsStringSync(), before);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), isFalse);
    });

    test('re-submitting every control a panel renders writes nothing, for every panel', () async {
      // The other save tests hand-craft a partial body; this one submits what
      // the browser would — every control the fragment emits, with unchecked
      // boxes omitted — which is the only shape that catches a field the form
      // renders empty and then reads back as an edit to the empty string.
      final before = File(configPath).readAsStringSync();
      final panels = surfacePanels(buildSurface());
      expect(panels.keys.toSet(), settingsPanels.where((panel) => panel.isForm).map((panel) => panel.id).toSet());

      final controlless = <String>[];
      for (final entry in panels.entries) {
        final body = _submissionFor(entry.value, entry.key);
        if (body.length == 1) controlless.add(entry.key);
        final response = await post(buildSurface(), body);
        final rendered = await response.readAsString();

        expect(response.statusCode, 200, reason: entry.key);
        expect(
          rendered,
          contains('No changes to save.'),
          reason: 'panel ${entry.key} reported a change it has not got',
        );
        expect(File(configPath).readAsStringSync(), before, reason: 'panel ${entry.key} wrote to dartclaw.yaml');
        expect(File(p.join(dataDir, 'restart.pending')).existsSync(), isFalse, reason: entry.key);
      }

      // Every other panel really did post controls, so the sweep is not vacuous.
      // The provider registry is a pure read-only projection and renders no
      // Save/Discard pair for the operator to press.
      expect(controlless, ['providers-config']);
      expect(panels['providers-config'], isNot(contains('form-actions')));
    });

    test('a key another panel owns is refused rather than written invisibly', () async {
      final before = File(configPath).readAsStringSync();
      final response = await post(buildSurface(), {settingsSectionFormField: 'context', 'agent.model': 'sonnet'});

      expect(response.statusCode, 400);
      expect(await response.readAsString(), contains('is not part of the Context section'));
      expect(File(configPath).readAsStringSync(), before);
    });

    test('a key another surface owns is refused, whatever section claims it', () async {
      final before = File(configPath).readAsStringSync();
      // settingsPanelForField answers null for these two prefixes, so the
      // cross-panel check above cannot see them. Both are writable strings, so
      // nothing else in the pipeline refuses them either.
      const ownedElsewhere = {
        'guards.content.model': 'The guard editor on the Security tab',
        'guards.content.classifier': 'The guard editor on the Security tab',
      };

      for (final entry in ownedElsewhere.entries) {
        for (final section in ['context', 'agent']) {
          final response = await post(buildSurface(), {settingsSectionFormField: section, entry.key: 'anything'});

          expect(response.statusCode, 400, reason: '${entry.key} under $section');
          final rendered = await response.readAsString();
          expect(rendered, contains('is not editable here'), reason: '${entry.key} under $section');
          expect(rendered, contains(entry.value), reason: '${entry.key} names its owning surface');
          expect(File(configPath).readAsStringSync(), before, reason: '${entry.key} under $section');
        }
      }
    });

    test('an unmodified section writes nothing and creates no restart marker', () async {
      final before = File(configPath).readAsStringSync();
      final response = await post(buildSurface(), {
        settingsSectionFormField: 'agent',
        'agent.provider': 'claude',
        'agent.model': 'opus',
        'agent.effort': 'high',
      });

      expect(response.statusCode, 200);
      expect(await response.readAsString(), contains('No changes to save.'));
      expect(File(configPath).readAsStringSync(), before);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), isFalse);
    });

    test('clearing an optional field removes the key instead of storing an empty string', () async {
      final response = await post(buildSurface(), {
        settingsSectionFormField: 'agent',
        'agent.provider': 'claude',
        'agent.model': 'opus',
        'agent.effort': '',
      });
      final body = await response.readAsString();
      final yaml = File(configPath).readAsStringSync();

      expect(response.statusCode, 200);
      expect(yaml, isNot(contains('effort:')));
      expect(_fieldGroup(body, 'agent.effort'), contains('value=""'));
    });

    test('a provider/model shorthand expands into both fields exactly as the JSON API does', () async {
      final response = await post(buildSurface(), {
        settingsSectionFormField: 'agent',
        'agent.provider': 'claude',
        'agent.model': 'codex/gpt-5.4',
        'agent.effort': 'high',
      });
      await response.readAsString();
      final yaml = File(configPath).readAsStringSync();

      expect(yaml, contains('model: gpt-5.4'));
      expect(yaml, contains('provider: codex'));
    });

    test('a handcrafted submission cannot reach a read-only field or a credential', () async {
      final before = File(configPath).readAsStringSync();
      final response = await post(buildSurface(), {
        settingsSectionFormField: 'agent',
        'guards.enabled': 'false',
        'credentials.anthropic.api_key': 'sk-ant-new-secret',
      });
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      // The same validator both tiers call, so the same sentences PATCH returns.
      expect(body, contains("Field 'guards.enabled' is read-only"));
      expect(body, contains("Unknown config field: 'credentials.anthropic.api_key'"));
      expect(body, isNot(contains('sk-ant-new-secret')));
      expect(File(configPath).readAsStringSync(), before);
    });

    test('a request without admin access is refused before anything is read or written', () async {
      final before = File(configPath).readAsStringSync();
      final registry = PageRegistry()..register(SettingsPage(settingsSurface: buildSurface()));
      final handler = webRoutes(sessions, MessageService(baseDir: tempDir.path), pageRegistry: registry).call;
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/settings'),
          body: '$settingsSectionFormField=agent&agent.model=sonnet',
          headers: const {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );

      expect(response.statusCode, 403);
      expect(await response.readAsString(), contains('Config changes require an admin user'));
      expect(File(configPath).readAsStringSync(), before);
    });
  });

  group('layout', () {
    test('related fields read as labelled groups and short numerics are capped', () async {
      final html = await renderPage(buildSurface());

      // Grouping, not decoration: each well is a named cluster with its own
      // accessible name, taken from the fields' shared parent path.
      expect(RegExp('class="well ').allMatches(html).length, greaterThanOrEqualTo(8));
      expect(RegExp('role="group"').allMatches(html).length, greaterThanOrEqualTo(8));
      for (final field in ['field-port', 'field-agent-max-turns', 'field-sessions-reset-hour']) {
        expect(
          RegExp('form-input--num[^>]*id="$field"').hasMatch(html),
          isTrue,
          reason: '$field spans the card measure for a two-character value',
        );
      }
      // The width scale is canon's; settings applies it and declares none.
      expect(html, isNot(contains('max-width')));
    });
  });

  group('label rendering', () {
    test('acronyms and camelCase keys read as labels rather than as typos', () {
      expect(humanizeSegment('base_url'), 'Base URL');
      expect(humanizeSegment('dm_scope'), 'DM Scope');
      expect(humanizeSegment('allowApiLocalPath'), 'Allow API Local Path');
      expect(labelFor('scheduling.heartbeat.interval_minutes'), 'Interval Minutes');
      expect(groupLabelFor('scheduling.heartbeat.interval_minutes'), 'Scheduling Heartbeat');
      expect(groupLabelFor('port'), isNull);
    });
  });
}

/// Every rendered form panel, keyed by panel id.
Map<String, String> surfacePanels(SettingsSurface surface) => surface.renderPanels();

/// The body a browser would send for [panelHtml]: every control the fragment
/// emits, at the value it was rendered with, with unchecked boxes omitted.
Map<String, String> _submissionFor(String panelHtml, String sectionId) {
  final body = <String, String>{settingsSectionFormField: sectionId};

  for (final match in RegExp('<input([^>]*)>').allMatches(panelHtml)) {
    final tag = match.group(1)!;
    final name = _attr(tag, 'name');
    if (name == null || name == settingsSectionFormField) continue;
    if (tag.contains('type="checkbox"')) {
      if (tag.contains('checked')) body[name] = 'true';
      continue;
    }
    body[name] = _attr(tag, 'value') ?? '';
  }

  for (final match in RegExp('<textarea([^>]*)>([\\s\\S]*?)</textarea>').allMatches(panelHtml)) {
    final name = _attr(match.group(1)!, 'name');
    if (name != null) body[name] = _unescape(match.group(2)!);
  }

  for (final match in RegExp('<select([^>]*)>([\\s\\S]*?)</select>').allMatches(panelHtml)) {
    final name = _attr(match.group(1)!, 'name');
    if (name == null) continue;
    final options = RegExp('<option([^>]*)>').allMatches(match.group(2)!).toList();
    final selected = options.where((option) => option.group(1)!.contains('selected'));
    final chosen = selected.isNotEmpty ? selected.first : (options.isEmpty ? null : options.first);
    body[name] = chosen == null ? '' : (_attr(chosen.group(1)!, 'value') ?? '');
  }

  return body;
}

String? _attr(String tag, String name) => RegExp('$name="([^"]*)"').firstMatch(tag)?.group(1);

String _unescape(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// The rendered `data-field` group for one path, isolated so an assertion
/// cannot be satisfied by markup belonging to another field.
String _fieldGroup(String html, String path) {
  final start = html.indexOf('data-field="$path"');
  expect(start, greaterThan(-1), reason: 'no rendered group for $path');
  final end = html.indexOf('data-field="', start + 1);
  return end == -1 ? html.substring(start) : html.substring(start, end);
}

PageContext _pageContext(SessionService sessions) => PageContext(
  sessions: sessions,
  sidebarData: () async => _emptySidebarData,
  restartBannerHtml: () => '',
  buildNavItems: ({required String activePage}) => const [],
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
