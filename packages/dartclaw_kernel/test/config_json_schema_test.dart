import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/config_schema_artifact.dart';
import 'support/json_schema_walker.dart';

/// The schema node at [path], following `properties`, `items` (`[]`) and a
/// schema-valued `additionalProperties` (`<entry>`).
Map<String, Object?> _node(Map<String, Object?> schema, String path) {
  var node = schema;
  for (final segment in path.split('.')) {
    final target = switch (segment) {
      '[]' => node['items'],
      '<entry>' => node['additionalProperties'],
      _ => (node['properties'] as Map?)?[segment],
    };
    expect(target, isA<Map<String, Object?>>(), reason: 'no schema node at $path (stopped at $segment)');
    node = (target! as Map).cast<String, Object?>();
  }
  return node;
}

void main() {
  final schema = ConfigMeta.toJsonSchema();
  final positions = schemaPositions(schema).toList();
  late String repoRoot;

  setUpAll(() async => repoRoot = await resolveRepoRoot());

  group('scalar constraints', () {
    test('an integer field carries both declared bounds, and only the bounds declared', () {
      expect(_node(schema, 'port'), containsPair('type', 'integer'));
      expect(_node(schema, 'port'), containsPair('minimum', 1));
      expect(_node(schema, 'port'), containsPair('maximum', 65535));

      final maxBytes = _node(schema, 'guards.content.max_bytes');
      expect(maxBytes, containsPair('minimum', 1));
      expect(maxBytes.containsKey('maximum'), isFalse, reason: 'no maximum is declared for guards.content.max_bytes');
    });

    test('an enumerated field emits its declared set as a string enum', () {
      expect(_node(schema, 'logging.level'), containsPair('type', 'string'));
      expect(_node(schema, 'logging.level')['enum'], ['FINE', 'INFO', 'SEVERE', 'WARNING']);
    });

    test('a nullable field admits null through its type, and through its enum when it has one', () {
      expect(_node(schema, 'channels.google_chat.service_account')['type'], ['null', 'string']);

      // Without null in the set, the one way to unset an enumerated field is
      // refused by the enum the widened type just admitted.
      final execution = _node(schema, 'agent.execution');
      expect(execution['type'], ['null', 'string']);
      expect(execution['enum'], contains(null));
      expect(execution['enum'], containsAll(<Object?>['host', 'container']));
    });

    test('a string list emits string items', () {
      expect(_node(schema, 'logging.redact_patterns')['items'], {'type': 'string'});
      expect(_node(schema, 'logging.redact_patterns')['type'], contains('array'));
    });

    test('a section is closed against an unknown key', () {
      expect(schema['additionalProperties'], false);
      expect(_node(schema, 'guards')['additionalProperties'], false);
    });

    test('no schema position carries required or default', () {
      for (final position in positions) {
        expect(position.containsKey('required'), isFalse);
        expect(position.containsKey('default'), isFalse);
      }
    });

    test('every read-only field describes itself as file-only', () {
      final readonly = ConfigMeta.forMutability(ConfigMutability.readonly).map((field) => field.yamlPath);
      expect(readonly, contains('guards.enabled'));
      for (final path in readonly) {
        final node = _node(schema, path);
        expect(node['description'], endsWith(' (file-only, not settable via API or CLI)'), reason: path);
      }
    });
  });

  group('entry-shaped fields', () {
    test('an operator-named entry is typed while a shapeless sub-map stays open', () {
      final entry = _node(schema, 'mcp_servers.<entry>');
      expect(entry['additionalProperties'], false);
      expect(_node(schema, 'mcp_servers.<entry>.network_class')['enum'], ['local', 'private', 'public']);
      expect(_node(schema, 'mcp_servers.<entry>.rate_limit.calls')['type'], 'integer');
    });

    test('an exactly declared path lands beside the entry shape rather than replacing it', () {
      final projects = _node(schema, 'projects');
      expect(projects['additionalProperties'], isA<Map<String, Object?>>());
      // The real YAML keys are camelCase; a segment-casing assumption here
      // would publish a key the loader never reads.
      expect(
        (projects['properties']! as Map).keys,
        containsAll(<String>['fetchCooldownMinutes', 'allowApiLocalPath', 'localPathAllowlist']),
      );
      expect(_node(schema, 'projects.<entry>.pr.labels')['items'], {'type': 'string'});
    });

    test('a list-valued field emits its entry shape as items', () {
      expect(_node(schema, 'agent.agents.<entry>.tools')['items'], {'type': 'string'});
      expect(_node(schema, 'guards.file.extra_rules.[].pattern')['type'], 'string');
      expect(_node(schema, 'guards.file.extra_rules.[].level')['enum'], ['no_access', 'no_delete', 'read_only']);
      expect(_node(schema, 'github.triggers.[]')['properties'], isA<Map<String, Object?>>());
    });

    test('channels stays open for a channel this registry does not know, and typed where it does', () {
      final channels = _node(schema, 'channels');
      expect(channels['additionalProperties'], {'type': 'object'});
      expect(_node(schema, 'channels.debounce_window_ms')['type'], 'integer');
      expect(_node(schema, 'channels.google_chat')['additionalProperties'], false);
    });

    test('an entry field inherits its container reload tier', () {
      expect(_node(schema, 'credentials')['description'], endsWith(' (file-only, not settable via API or CLI)'));
      expect(
        _node(schema, 'credentials.<entry>.api_key')['description'],
        endsWith(' (file-only, not settable via API or CLI)'),
      );
    });
  });

  group('unions', () {
    test('a boolean alternative widens the type and contributes its literals to the enum', () {
      final node = _node(schema, 'channels.google_chat.typing_indicator');
      expect(node['type'], ['boolean', 'string']);
      expect(node['enum'], containsAll(<Object?>['disabled', 'message', 'emoji', 'true', 'false', true, false]));
    });

    test('a scalar-or-mapping field emits one node carrying both arms, the mapping still closed', () {
      final node = _node(schema, 'scheduling.jobs.[].schedule');
      expect(node['type'], ['object', 'string']);
      expect(node['additionalProperties'], false);
      expect((node['properties']! as Map).keys, unorderedEquals(<String>['type', 'expression', 'minutes', 'at']));
      expect(_node(schema, 'scheduling.jobs.[].schedule.minutes')['type'], contains('integer'));
    });

    test('a string alternative widens the type without dropping the declared bounds', () {
      final node = _node(schema, 'governance.rate_limits.global.window');
      expect(node['type'], ['integer', 'string']);
      expect(node['minimum'], 1);
      expect(node['maximum'], 1440);
    });

    test('turn limits accept non-negative integer seconds and duration strings', () {
      for (final path in ['governance.turn_limits.stall_timeout', 'governance.turn_limits.turn_timeout']) {
        final node = _node(schema, path);
        expect(node['type'], ['integer', 'string'], reason: path);
        expect(node['minimum'], 0, reason: path);
      }
    });

    test('the divergence this story declines to widen is untouched', () {
      expect(ConfigMeta.fields['channels.google_chat.quote_reply']!.allowedValues, ['disabled', 'sender', 'native']);
      expect(_node(schema, 'channels.google_chat.quote_reply')['type'], 'string');
    });

    test('no emitter branch is keyed on a config path', () async {
      final source = File(
        p.join(repoRoot, 'packages', 'dartclaw_kernel', 'lib', 'src', 'config_meta', 'json_schema.dart'),
      ).readAsStringSync();
      final registered = ConfigMeta.fields.keys.where((path) => source.contains("'$path'"));
      expect(registered, isEmpty, reason: 'the emitter names config paths: $registered');
    });
  });

  group('mutability is described, never enforced', () {
    test('no schema position carries an annotation derived from mutability', () {
      for (final position in positions) {
        expect(position.containsKey('readOnly'), isFalse);
        expect(position.containsKey('writeOnly'), isFalse);
        expect(position.containsKey('deprecated'), isFalse);
      }
    });

    test('describing a read-only field grants no write access', () {
      expect(ConfigMeta.isWritable('guards.enabled'), isFalse);
      expect(ConfigMeta.isWritable('guards.fail_open'), isFalse);
      expect(ConfigMeta.isWritable('credentials'), isFalse);
    });

    test('the emitted artifact has no in-workspace reader that could parse a tier back out', () {
      // The tier is description prose. Nothing may consume the artifact as a
      // source of field metadata — the registry is that source.
      final offenders = <String>[];
      for (final package in Directory(p.join(repoRoot, 'packages')).listSync().whereType<Directory>()) {
        final lib = Directory(p.join(package.path, 'lib'));
        if (!lib.existsSync()) continue;
        for (final file in lib.listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          if (file.readAsStringSync().contains('dartclaw.schema.json')) offenders.add(file.path);
        }
      }
      expect(offenders, isEmpty, reason: 'the published schema is being read back: $offenders');
    });
  });

  group('the emitted vocabulary is closed', () {
    test('no schema position carries a keyword or a type name outside the emitted set', () {
      for (final position in positions) {
        expect(position.keys.toSet().difference(emittedKeywords), isEmpty, reason: '$position');
        final declared = position['type'];
        final names = declared is List ? declared.cast<String>() : [if (declared != null) declared as String];
        expect(names.toSet().difference(emittedTypes), isEmpty, reason: '$position');
        expect(names, orderedEquals(names.toList()..sort()), reason: 'a type list must be sorted: $position');
      }
    });

    test('a config key that shares a keyword name does not trip the closure check', () {
      // These are real config keys, not schema keywords; a name-based scan
      // would red a correct artifact.
      expect((_node(schema, 'projects.<entry>')['properties']! as Map).keys, contains('default'));
      expect((_node(schema, 'scheduling.jobs.[].task')['properties']! as Map).keys, contains('title'));
      expect((_node(schema, 'credentials.<entry>')['properties']! as Map).keys, contains('type'));
    });

    test('the root declares the dialect and a fixed title, and claims no published identity', () {
      expect(schema[r'$schema'], 'https://json-schema.org/draft/2020-12/schema');
      expect(schema['title'], 'DartClaw configuration');
      expect(schema.containsKey(r'$id'), isFalse);
    });
  });

  group('the committed artifact', () {
    late File artifact;

    setUpAll(() async {
      repoRoot = await resolveRepoRoot();
      artifact = File(configSchemaPath(repoRoot));
    });

    test('is byte-identical to what the generator would write', () {
      expect(artifact.existsSync(), isTrue, reason: 'run: $configSchemaRegenerationCommand');
      expect(
        configSchemaDrift(
          artifactPath: artifact.path,
          committed: artifact.readAsStringSync(),
          rendered: renderConfigSchema(),
        ),
        isNull,
      );
    });

    test('is a function of registry content, so rendering twice changes nothing', () {
      expect(renderConfigSchema(), renderConfigSchema());
      expect(renderConfigSchema(), endsWith('}\n'));
      expect(jsonDecode(renderConfigSchema()), isA<Map<String, Object?>>());
    });

    test('drift and absence both report the artifact and the regeneration command', () {
      final path = configSchemaPath(repoRoot);
      expect(
        configSchemaDrift(artifactPath: path, committed: renderConfigSchema(), rendered: renderConfigSchema()),
        isNull,
      );

      final drifted = configSchemaDrift(artifactPath: path, committed: '{}\n', rendered: renderConfigSchema());
      expect(drifted, allOf(contains(path), contains(configSchemaRegenerationCommand), contains('drifted')));

      final missing = configSchemaDrift(artifactPath: path, committed: null, rendered: renderConfigSchema());
      expect(missing, allOf(contains(path), contains(configSchemaRegenerationCommand), contains('missing')));
    });

    test('a CRLF checkout does not read as drift', () {
      final crlf = renderConfigSchema().replaceAll('\n', '\r\n');
      expect(
        configSchemaDrift(
          artifactPath: 'schemas/dartclaw.schema.json',
          committed: crlf,
          rendered: renderConfigSchema(),
        ),
        isNull,
      );
    });
  });
}
