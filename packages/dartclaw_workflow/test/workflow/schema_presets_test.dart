import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

/// Collects every leaf property schema from an object preset so we can assert
/// that each property carries a JSON Schema `description`.
List<MapEntry<String, Map<String, dynamic>>> _collectProperties(
  Map<String, dynamic> schema, {
  String prefix = '',
}) {
  final out = <MapEntry<String, Map<String, dynamic>>>[];

  void visit(Map<String, dynamic> node, String path) {
    final props = node['properties'] as Map<String, dynamic>?;
    if (props == null) return;
    for (final e in props.entries) {
      final prop = e.value as Map<String, dynamic>;
      final fullPath = path.isEmpty ? e.key : '$path.${e.key}';
      out.add(MapEntry(fullPath, prop));

      final type = prop['type'];
      final isObject = type == 'object' || (type is List && type.contains('object'));
      final isArray = type == 'array' || (type is List && type.contains('array'));
      if (isObject) {
        visit(prop, fullPath);
      } else if (isArray) {
        final items = prop['items'] as Map<String, dynamic>?;
        if (items != null) visit(items, '$fullPath[]');
      }
    }
  }

  visit(schema, prefix);
  return out;
}

void main() {
  group('SchemaPreset constants', () {
    test('all presets exist in registry', () {
      expect(schemaPresets.containsKey('verdict'), true);
      expect(schemaPresets.containsKey('remediation-result'), true);
      expect(schemaPresets.containsKey('story-plan'), true);
      expect(schemaPresets.containsKey('story-specs'), true);
      expect(schemaPresets.containsKey('file-list'), true);
      expect(schemaPresets.containsKey('checklist'), true);
      expect(schemaPresets.containsKey('project-index'), true);
      expect(schemaPresets.containsKey('non-negative-integer'), true);
      expect(schemaPresets.containsKey('diff-summary'), true);
      expect(schemaPresets.containsKey('validation-summary'), true);
      expect(schemaPresets.containsKey('state-update-summary'), true);
      expect(schemaPresets.containsKey('remediation-summary'), true);
      expect(schemaPresets.containsKey('story-result'), true);
    });

    test('each preset has non-empty name', () {
      for (final preset in schemaPresets.values) {
        expect(preset.name, isNotEmpty);
      }
    });

    test('each preset schema has a type field', () {
      for (final preset in schemaPresets.values) {
        expect(preset.schema.containsKey('type'), true);
      }
    });

    test('each object preset disables additional properties', () {
      for (final preset in schemaPresets.values) {
        if (preset.schema['type'] == 'object') {
          expect(preset.schema['additionalProperties'], isFalse, reason: preset.name);
        }
      }
    });

    // A "text preset" is one whose schema represents a plain string value —
    // the schema section isn't rendered for text outputs, so those presets
    // omit promptFragment and rely on `description` instead. "JSON presets"
    // cover object/array/integer/boolean shapes; their shape is documented
    // via per-property JSON Schema `description` fields and must NOT set the
    // preset-level `description` (doing so would affect every workflow using
    // them — see `PromptAugmenter.effectiveDescription`).
    test('text presets have description, no promptFragment', () {
      for (final preset in schemaPresets.values) {
        if (preset.schema['type'] != 'string') continue;
        expect(
          preset.promptFragment,
          isNull,
          reason: '"${preset.name}" is a text preset — promptFragment is dead code for text outputs.',
        );
        expect(
          preset.description,
          isNotNull,
          reason: '"${preset.name}" is a text preset — description carries its canonical meaning.',
        );
        expect(preset.description, isNotEmpty, reason: preset.name);
      }
    });

    test('JSON object/array presets have per-property descriptions and no preset-level description', () {
      for (final preset in schemaPresets.values) {
        final type = preset.schema['type'];
        if (type != 'object' && type != 'array') continue;
        expect(
          preset.description,
          isNull,
          reason:
              '"${preset.name}" is a structured preset — setting description would silently affect every '
              'workflow using this preset via PromptAugmenter.effectiveDescription.',
        );
        final properties = _collectProperties(preset.schema);
        expect(
          properties,
          isNotEmpty,
          reason: '"${preset.name}" should expose at least one property.',
        );
        for (final entry in properties) {
          final desc = entry.value['description'];
          expect(
            desc,
            isA<String>(),
            reason: '"${preset.name}".${entry.key} is missing a JSON Schema `description`.',
          );
          expect(
            (desc as String).trim(),
            isNotEmpty,
            reason: '"${preset.name}".${entry.key} has an empty description.',
          );
        }
      }
    });
  });

  group('verdictPreset', () {
    test('has correct name', () {
      expect(verdictPreset.name, 'verdict');
    });

    test('schema is an object type', () {
      expect(verdictPreset.schema['type'], 'object');
    });

    test('schema requires pass, findings_count, findings, summary', () {
      final required = verdictPreset.schema['required'] as List;
      expect(required, containsAll(['pass', 'findings_count', 'findings', 'summary']));
    });

    test('finding item severity uses enum', () {
      final findings = (verdictPreset.schema['properties'] as Map)['findings'] as Map;
      final item = findings['items'] as Map;
      final severity = (item['properties'] as Map)['severity'] as Map;
      expect(severity['enum'], containsAll(['critical', 'high', 'medium', 'low']));
    });
  });

  group('storyPlanPreset', () {
    test('has correct name', () {
      expect(storyPlanPreset.name, 'story-plan');
    });

    test('schema is an object envelope type', () {
      expect(storyPlanPreset.schema['type'], 'object');
    });

    test('schema item requires id, title, description', () {
      final items = (storyPlanPreset.schema['properties'] as Map)['items'] as Map;
      final itemSchema = items['items'] as Map;
      final required = itemSchema['required'] as List;
      expect(required, containsAll(['id', 'title', 'description']));
    });

    test('schema envelope requires items', () {
      final required = storyPlanPreset.schema['required'] as List;
      expect(required, contains('items'));
    });
  });

  group('storySpecsPreset', () {
    test('has correct name', () {
      expect(storySpecsPreset.name, 'story-specs');
    });

    test('schema is an object envelope type', () {
      expect(storySpecsPreset.schema['type'], 'object');
      expect(storySpecsPreset.schema['additionalProperties'], isFalse);
    });

    test('schema item requires foreach-driving fields only', () {
      final items = (storySpecsPreset.schema['properties'] as Map)['items'] as Map;
      final itemSchema = items['items'] as Map;
      final required = itemSchema['required'] as List;
      // Slim contract: id + title for display/routing, spec_path for FIS
      // resolution. Acceptance criteria and all other detail live in the FIS
      // body on disk at spec_path; plan-level detail lives in plan.md.
      expect(required, unorderedEquals(['id', 'title', 'spec_path']));
    });

    test('acceptance_criteria is not part of the story-specs contract', () {
      final items = (storySpecsPreset.schema['properties'] as Map)['items'] as Map;
      final itemSchema = items['items'] as Map;
      final required = itemSchema['required'] as List;
      final props = itemSchema['properties'] as Map;
      // Single source of truth: AC lives in the FIS body on disk. Including
      // it in the structured record invited drift between the two copies.
      expect(required, isNot(contains('acceptance_criteria')));
      expect(props.containsKey('acceptance_criteria'), isFalse);
      expect(itemSchema['additionalProperties'], isFalse,
          reason: 'additionalProperties:false ensures plan skills cannot silently re-emit acceptance_criteria');
    });

    test('schema envelope requires items', () {
      final required = storySpecsPreset.schema['required'] as List;
      expect(required, contains('items'));
    });

    test('spec_path property is present (naming aligns with validator + workflow prompts)', () {
      final items = (storySpecsPreset.schema['properties'] as Map)['items'] as Map;
      final itemSchema = items['items'] as Map;
      final props = itemSchema['properties'] as Map;
      expect(props.containsKey('spec_path'), isTrue, reason: 'schema must use spec_path (not path) for FIS location');
      expect(props.containsKey('path'), isFalse, reason: 'legacy `path` field must not be present');
    });
  });

  group('fileListPreset', () {
    test('has correct name', () {
      expect(fileListPreset.name, 'file-list');
    });

    test('schema is an object envelope type', () {
      expect(fileListPreset.schema['type'], 'object');
    });

    test('schema item requires path', () {
      final items = (fileListPreset.schema['properties'] as Map)['items'] as Map;
      final itemSchema = items['items'] as Map;
      final required = itemSchema['required'] as List;
      expect(required, contains('path'));
    });
  });

  group('checklistPreset', () {
    test('has correct name', () {
      expect(checklistPreset.name, 'checklist');
    });

    test('schema is an object type', () {
      expect(checklistPreset.schema['type'], 'object');
    });

    test('schema requires items and all_pass', () {
      final required = checklistPreset.schema['required'] as List;
      expect(required, containsAll(['items', 'all_pass']));
    });
  });

  group('registry lookup', () {
    test('lookup by name returns correct preset', () {
      expect(schemaPresets['verdict'], verdictPreset);
      expect(schemaPresets['remediation-result'], remediationResultPreset);
      expect(schemaPresets['story-plan'], storyPlanPreset);
      expect(schemaPresets['story-specs'], storySpecsPreset);
      expect(schemaPresets['file-list'], fileListPreset);
      expect(schemaPresets['checklist'], checklistPreset);
    });

    test('unknown preset name returns null', () {
      expect(schemaPresets['unknown-preset'], isNull);
    });
  });
}
