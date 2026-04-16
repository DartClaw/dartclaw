import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaPreset constants', () {
    test('all 5 presets exist in registry', () {
      expect(schemaPresets.containsKey('verdict'), true);
      expect(schemaPresets.containsKey('remediation-result'), true);
      expect(schemaPresets.containsKey('story-plan'), true);
      expect(schemaPresets.containsKey('file-list'), true);
      expect(schemaPresets.containsKey('checklist'), true);
    });

    test('each preset has non-empty name', () {
      for (final preset in schemaPresets.values) {
        expect(preset.name, isNotEmpty);
      }
    });

    test('each preset has a non-empty prompt fragment', () {
      for (final preset in schemaPresets.values) {
        expect(preset.promptFragment, isNotEmpty);
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

    test('prompt fragment mentions pass boolean', () {
      expect(verdictPreset.promptFragment, contains('pass'));
      expect(verdictPreset.promptFragment, contains('boolean'));
    });

    test('prompt fragment mentions findings', () {
      expect(verdictPreset.promptFragment, contains('findings'));
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

    test('prompt fragment describes object envelope', () {
      expect(storyPlanPreset.promptFragment, contains('JSON object with an `items` array'));
    });

    test('prompt fragment mentions dependencies', () {
      expect(storyPlanPreset.promptFragment, contains('dependencies'));
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

    test('prompt fragment describes object envelope', () {
      expect(fileListPreset.promptFragment, contains('JSON object with an `items` array'));
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

    test('prompt fragment mentions all_pass', () {
      expect(checklistPreset.promptFragment, contains('all_pass'));
    });
  });

  group('registry lookup', () {
    test('lookup by name returns correct preset', () {
      expect(schemaPresets['verdict'], verdictPreset);
      expect(schemaPresets['remediation-result'], remediationResultPreset);
      expect(schemaPresets['story-plan'], storyPlanPreset);
      expect(schemaPresets['file-list'], fileListPreset);
      expect(schemaPresets['checklist'], checklistPreset);
    });

    test('unknown preset name returns null', () {
      expect(schemaPresets['unknown-preset'], isNull);
    });
  });
}
