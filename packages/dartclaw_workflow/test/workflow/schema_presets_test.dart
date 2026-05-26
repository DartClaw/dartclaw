import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

/// Collects every leaf property schema from an object preset so we can assert
/// that each property carries a JSON Schema `description`.
List<MapEntry<String, Map<String, dynamic>>> _collectProperties(Map<String, dynamic> schema, {String prefix = ''}) {
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
      expect(schemaPresets.containsKey('remediation_result'), true);
      expect(schemaPresets.containsKey('story_plan'), true);
      expect(schemaPresets.containsKey('story_specs'), true);
      expect(schemaPresets.containsKey('file_list'), true);
      expect(schemaPresets.containsKey('checklist'), true);
      expect(schemaPresets.containsKey('non_negative_integer'), true);
      expect(schemaPresets.containsKey('diff_summary'), true);
      expect(schemaPresets.containsKey('validation_summary'), true);
      expect(schemaPresets.containsKey('state_update_summary'), true);
      expect(schemaPresets.containsKey('remediation_summary'), true);
      expect(schemaPresets.containsKey('story_result'), true);
      expect(schemaPresets.containsKey('gating_findings_count'), true);
      expect(schemaPresets.containsKey('findings_count'), true);
      expect(schemaPresets.containsKey('review_report_path'), true);
      expect(schemaPresets.containsKey('prd_path'), true);
      expect(schemaPresets.containsKey('plan_path'), true);
      expect(schemaPresets.containsKey('fis_path'), true);
      expect(schemaPresets.containsKey('detected_fis_path'), true);
      expect(schemaPresets.containsKey('spec_source'), true);
      expect(schemaPresets.containsKey('spec_confidence'), true);
    });

    test('each preset declares its effective output format', () {
      const expected = {
        'verdict': OutputFormat.json,
        'remediation_result': OutputFormat.json,
        'story_plan': OutputFormat.json,
        'story_specs': OutputFormat.json,
        'file_list': OutputFormat.json,
        'checklist': OutputFormat.json,
        'non_negative_integer': OutputFormat.json,
        'diff_summary': OutputFormat.text,
        'validation_summary': OutputFormat.text,
        'state_update_summary': OutputFormat.text,
        'remediation_summary': OutputFormat.text,
        'story_result': OutputFormat.text,
        'gating_findings_count': OutputFormat.json,
        'findings_count': OutputFormat.json,
        'review_report_path': OutputFormat.path,
        'prd_path': OutputFormat.path,
        'plan_path': OutputFormat.path,
        'fis_path': OutputFormat.path,
        'detected_fis_path': OutputFormat.path,
        'spec_source': OutputFormat.text,
        'spec_confidence': OutputFormat.json,
      };

      expect(schemaPresets.keys, containsAll(expected.keys));
      for (final entry in expected.entries) {
        expect(schemaPresets[entry.key]!.format, entry.value, reason: entry.key);
      }
    });

    test('preset names cannot shadow shorthand format keywords', () {
      for (final format in OutputFormat.values) {
        expect(schemaPresets.containsKey(format.name), isFalse);
      }
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

    test('each non-path preset declares an output resolver', () {
      for (final preset in schemaPresets.values) {
        if (preset.format == OutputFormat.path) continue;
        expect(
          preset.defaultResolver ?? preset.fieldResolvers.values.firstOrNull,
          isNotNull,
          reason: '"${preset.name}" must declare how outputs resolve.',
        );
      }
    });

    test('declares resolver type per canonical field', () {
      expect(
        outputResolverFor('story_specs', const OutputConfig(format: OutputFormat.json, schema: 'story_specs')),
        isA<InlineOutput>(),
      );
      expect(
        outputResolverFor(
          'spec_confidence',
          const OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        ),
        isA<NarrativeOutput>(),
      );
      expect(outputResolverFor('plan', const OutputConfig(format: OutputFormat.path)), isA<FileSystemOutput>());
    });

    test('plan path outputs use the narrowed plan.{json,md} default pattern', () {
      final plan = outputResolverFor('plan', const OutputConfig(format: OutputFormat.path)) as FileSystemOutput;
      final planPath =
          outputResolverFor('plan_path', const OutputConfig(format: OutputFormat.path)) as FileSystemOutput;

      expect(plan.pathPattern, '**/*plan.{json,md}');
      expect(planPath.pathPattern, '**/*plan.{json,md}');

      // Accepts canonical plan.json/plan.md and dashed variants.
      expect(plan.matches('docs/plans/demo/plan.json'), isTrue);
      expect(plan.matches('docs/plans/demo/sample-plan.json'), isTrue);
      expect(plan.matches('docs/plans/demo/plan.md'), isTrue);
      expect(plan.matches('docs/plans/demo/sample-plan.md'), isTrue);

      // Rejects unrelated plan-named files that the old `**/*plan*.*` pattern
      // would have matched (review reports, implementation notes, etc.).
      expect(plan.matches('docs/plans/demo/plan-review.md'), isFalse);
      expect(plan.matches('docs/plans/demo/plan-notes.txt'), isFalse);
      expect(plan.matches('docs/plans/demo/myplan-report.json'), isFalse);
    });

    test('prd path outputs accept prd.md and dashed PRD filenames', () {
      final prd = outputResolverFor('prd', const OutputConfig(format: OutputFormat.path)) as FileSystemOutput;

      expect(prd.matches('docs/specs/demo/prd.md'), isTrue);
      expect(prd.matches('docs/specs/demo/demo-prd.md'), isTrue);
      expect(prd.matches('docs/specs/demo/prd-draft.md'), isFalse);
    });

    test('infers filesystem resolver for legacy path output without preset resolver', () {
      final resolver = outputResolverFor('artifact_path', const OutputConfig(format: OutputFormat.path));

      expect(resolver, isA<FileSystemOutput>());
      final filesystem = resolver as FileSystemOutput;
      expect(filesystem.authoritative, isTrue);
      expect(filesystem.pathPattern, '**/*');
    });

    test('path presets preserve key-specific filesystem resolver patterns', () {
      final prd = outputResolverFor('prd', const OutputConfig(format: OutputFormat.path, schema: 'prd_path'));
      final plan = outputResolverFor('plan', const OutputConfig(format: OutputFormat.path, schema: 'plan_path'));
      final review = outputResolverFor(
        'review_findings',
        const OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
      );

      expect((prd as FileSystemOutput).pathPattern, '**/*prd.md');
      expect((plan as FileSystemOutput).pathPattern, '**/*plan.{json,md}');
      expect((review as FileSystemOutput).pathPattern, '**/*review*.md');
    });

    test('new presets expose canonical descriptions and schemas', () {
      expect(gatingFindingsCountPreset.schema, {'type': 'integer', 'minimum': 0});
      expect(gatingFindingsCountPreset.description, contains('MEDIUM-or-higher severity findings'));
      expect(findingsCountPreset.description, 'Number of issues flagged by this review; 0 means clean.');
      expect(reviewReportPathPreset.description, contains('--output-dir'));
      expect(
        reviewReportPathPreset.description,
        matches(RegExp(r'absolute.{0,80}--output-dir.{0,80}andthen:review', dotAll: true)),
        reason: 'andthen:review must be paired with the absolute / --output-dir form, not project-root-relative',
      );
      expect(
        reviewReportPathPreset.description,
        matches(
          RegExp(r'project-root-relative.{0,80}review-report-location\.md.{0,80}andthen:architecture', dotAll: true),
        ),
        reason: 'andthen:architecture must be paired with the project-root-relative / review-report-location.md form',
      );
      expect(prdPathPreset.description, 'Workspace-relative path to the required PRD on disk.');
      expect(planPathPreset.description, contains('plan.json'));
      expect(fisPathPreset.description, contains('FIS on disk'));
      expect(detectedFisPathPreset.description, contains('empty when input requires spec synthesis'));
      expect(specSourcePreset.description, contains("'existing'"));
      expect(specSourcePreset.description, contains("'synthesized'"));
      expect(specConfidencePreset.description, contains('1-10'));
      expect(specConfidencePreset.description, contains('revise-spec'));
      expect(storySpecsPreset.description, contains('foreach controller'));
      expect(
        outputResolverFor('gating_findings_count', const OutputConfig(schema: 'gating_findings_count')),
        isA<NarrativeOutput>(),
      );
      expect(outputResolverFor('findings_count', const OutputConfig(schema: 'findings_count')), isA<NarrativeOutput>());
      expect(outputResolverFor('spec_source', const OutputConfig(schema: 'spec_source')), isA<NarrativeOutput>());
      expect(
        outputResolverFor('spec_confidence', const OutputConfig(schema: 'spec_confidence')),
        isA<NarrativeOutput>(),
      );
    });

    test('each object preset disables additional properties', () {
      for (final preset in schemaPresets.values) {
        if (preset.schema['type'] == 'object') {
          expect(preset.schema['additionalProperties'], isFalse, reason: preset.name);
        }
      }
    });

    // A "text preset" is one whose schema represents a plain string value –
    // the schema section isn't rendered for text outputs, so those presets
    // omit promptFragment and rely on `description` instead. "JSON presets"
    // cover object/array/integer/boolean shapes; their shape is documented
    // via per-property JSON Schema `description` fields and must NOT set the
    // preset-level `description` (doing so would affect every workflow using
    // them – see `PromptAugmenter.effectiveDescription`).
    test('text presets have description, no promptFragment', () {
      for (final preset in schemaPresets.values) {
        if (preset.schema['type'] != 'string') continue;
        expect(
          preset.promptFragment,
          isNull,
          reason: '"${preset.name}" is a text preset – promptFragment is dead code for text outputs.',
        );
        expect(
          preset.description,
          isNotNull,
          reason: '"${preset.name}" is a text preset – description carries its canonical meaning.',
        );
        expect(preset.description, isNotEmpty, reason: preset.name);
      }
    });

    // Structured presets (object/array schemas) must always carry per-property
    // descriptions – those drive the rendered JSON Schema section. By default
    // they must NOT carry a preset-level `description`, because that
    // description fills `OutputConfig`'s description-fallback for the
    // string-shorthand form (`outputs: { key: preset_name }`) via
    // PromptAugmenter.effectiveDescription and would silently affect every
    // workflow using the preset. Presets that DO declare a canonical
    // preset-level role description must opt in via the explicit allowlist
    // below.
    const structuredPresetsWithRoleDescription = {'story_specs'};

    test('JSON object/array presets have per-property descriptions', () {
      for (final preset in schemaPresets.values) {
        final type = preset.schema['type'];
        if (type != 'object' && type != 'array') continue;

        if (structuredPresetsWithRoleDescription.contains(preset.name)) {
          expect(
            preset.description,
            isNotNull,
            reason:
                '"${preset.name}" is on the role-description allowlist – it must declare a preset-level description.',
          );
        } else {
          expect(
            preset.description,
            isNull,
            reason:
                '"${preset.name}" is a structured preset – setting `description` would silently affect every '
                'workflow using this preset via PromptAugmenter.effectiveDescription. Add the preset name to '
                '`structuredPresetsWithRoleDescription` if a canonical role description is genuinely shared by every '
                'call site.',
          );
        }

        final properties = _collectProperties(preset.schema);
        expect(properties, isNotEmpty, reason: '"${preset.name}" should expose at least one property.');
        for (final entry in properties) {
          final desc = entry.value['description'];
          expect(desc, isA<String>(), reason: '"${preset.name}".${entry.key} is missing a JSON Schema `description`.');
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
      expect(storyPlanPreset.name, 'story_plan');
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
      expect(storySpecsPreset.name, 'story_specs');
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
      // resolution, and dependencies for dependency-aware foreach scheduling.
      // Acceptance criteria and all other detail live in the FIS body on disk
      // at spec_path; plan-level detail lives in plan.md.
      expect(required, unorderedEquals(['id', 'title', 'spec_path', 'dependencies']));
    });

    test('acceptance_criteria is not part of the story_specs contract', () {
      final items = (storySpecsPreset.schema['properties'] as Map)['items'] as Map;
      final itemSchema = items['items'] as Map;
      final required = itemSchema['required'] as List;
      final props = itemSchema['properties'] as Map;
      // Single source of truth: AC lives in the FIS body on disk. Including
      // it in the structured record invited drift between the two copies.
      expect(required, isNot(contains('acceptance_criteria')));
      expect(props.containsKey('acceptance_criteria'), isFalse);
      expect(
        itemSchema['additionalProperties'],
        isFalse,
        reason: 'additionalProperties:false ensures plan skills cannot silently re-emit acceptance_criteria',
      );
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

    test('dependencies property is present for dependency-aware story fan-out', () {
      final items = (storySpecsPreset.schema['properties'] as Map)['items'] as Map;
      final itemSchema = items['items'] as Map;
      final props = itemSchema['properties'] as Map;
      expect(props.containsKey('dependencies'), isTrue);
      expect(props['dependencies'], isA<Map<Object?, Object?>>());
    });
  });

  group('fileListPreset', () {
    test('has correct name', () {
      expect(fileListPreset.name, 'file_list');
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
      expect(schemaPresets['remediation_result'], remediationResultPreset);
      expect(schemaPresets['story_plan'], storyPlanPreset);
      expect(schemaPresets['story_specs'], storySpecsPreset);
      expect(schemaPresets['file_list'], fileListPreset);
      expect(schemaPresets['checklist'], checklistPreset);
      expect(schemaPresets['gating_findings_count'], gatingFindingsCountPreset);
      expect(schemaPresets['findings_count'], findingsCountPreset);
      expect(schemaPresets['review_report_path'], reviewReportPathPreset);
      expect(schemaPresets['prd_path'], prdPathPreset);
      expect(schemaPresets['plan_path'], planPathPreset);
      expect(schemaPresets['fis_path'], fisPathPreset);
    });

    test('unknown preset name returns null', () {
      expect(schemaPresets['unknown-preset'], isNull);
    });
  });
}
