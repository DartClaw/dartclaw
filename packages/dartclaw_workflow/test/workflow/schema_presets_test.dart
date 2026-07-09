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

/// Framework vocabulary that must not leak into any preset-facing text.
final _forbiddenVocab = RegExp(
  r'\bFIS\b|Fix/Note|review-verdict\.md|fis-authoring-guidelines\.md|\bPRD\b|AndThen|review-report-location\.md',
);

/// Fails (naming the offending preset + surface) when any preset's description,
/// per-property schema description, or promptFragment carries framework
/// vocabulary. Takes a preset list so a seeded-violation test can inject
/// synthetic presets rather than mutating the real registry.
void expectPresetsFrameworkNeutral(Iterable<SchemaPreset> presets) {
  for (final preset in presets) {
    void check(String surface, Object? text) {
      if (text is! String) return;
      expect(
        text,
        isNot(matches(_forbiddenVocab)),
        reason: '"${preset.name}" ($surface) carries framework vocabulary: "$text"',
      );
    }

    check('description', preset.description);
    check('promptFragment', preset.promptFragment);
    for (final entry in _collectProperties(preset.schema)) {
      check('property ${entry.key}', entry.value['description']);
    }
  }
}

void main() {
  group('SchemaPreset constants', () {
    test('all presets exist in registry', () {
      expect(schemaPresets.containsKey('verdict'), true);
      expect(schemaPresets.containsKey('story_specs'), true);
      expect(schemaPresets.containsKey('non_negative_integer'), true);
      expect(schemaPresets.containsKey('narrative_text'), true);
      expect(schemaPresets.containsKey('diff_summary'), true);
      expect(schemaPresets.containsKey('validation_summary'), true);
      expect(schemaPresets.containsKey('gating_findings_count'), true);
      expect(schemaPresets.containsKey('findings_count'), true);
      expect(schemaPresets.containsKey('review_report_path'), true);
      for (final name in const [
        'fis_path',
        'detected_fis_path',
        'spec_source',
        'spec_confidence',
        'story_result',
        'remediation_result',
        'remediation_summary',
        'prd_path',
        'plan_path',
      ]) {
        expect(schemaPresets.containsKey(name), isFalse, reason: name);
      }
    });

    test('each preset declares its effective output format', () {
      const expected = {
        'verdict': OutputFormat.json,
        'story_specs': OutputFormat.json,
        'non_negative_integer': OutputFormat.json,
        'narrative_text': OutputFormat.text,
        'diff_summary': OutputFormat.text,
        'validation_summary': OutputFormat.text,
        'gating_findings_count': OutputFormat.json,
        'findings_count': OutputFormat.json,
        'review_report_path': OutputFormat.path,
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
        isA<InlineOutput>(),
      );
      expect(outputResolverFor('plan', const OutputConfig(format: OutputFormat.path)), isA<FileSystemOutput>());
    });

    test('framework output keys no longer get narrative behavior by key-name heuristic', () {
      for (final entry in const {
        'spec_source': OutputConfig(format: OutputFormat.text),
        'spec_confidence': OutputConfig(format: OutputFormat.json),
        'story_result': OutputConfig(format: OutputFormat.text),
        'remediation_summary': OutputConfig(format: OutputFormat.text),
      }.entries) {
        expect(outputResolverFor(entry.key, entry.value), isA<InlineOutput>(), reason: entry.key);
      }
    });

    test('bare prd/plan path outputs fall back to the generic default after preset relocation', () {
      // The prd_path/plan_path presets and their _defaultPathPattern arms were
      // removed; the built-in workflows now declare the narrowed globs inline
      // (see built_in_workflow_contracts_test.dart S03). A non-shipped workflow
      // that declares a bare `prd:`/`plan:` path output now resolves the generic
      // `**/*` default – accepted breaking change (early-experimental stage).
      final prd = outputResolverFor('prd', const OutputConfig(format: OutputFormat.path)) as FileSystemOutput;
      final plan = outputResolverFor('plan', const OutputConfig(format: OutputFormat.path)) as FileSystemOutput;
      expect(prd.pathPattern, '**/*');
      expect(plan.pathPattern, '**/*');
    });

    test('infers filesystem resolver for legacy path output without preset resolver', () {
      final resolver = outputResolverFor('artifact_path', const OutputConfig(format: OutputFormat.path));

      expect(resolver, isA<FileSystemOutput>());
      final filesystem = resolver as FileSystemOutput;
      expect(filesystem.pathPattern, '**/*');
    });

    test('review_report_path preset resolves the uniform glob (name-agnostic; recognition is preset-based)', () {
      // The preset carries no key-specific pattern: review-artifact recognition
      // keys on the preset itself (see review_artifact_policy), and the unclaimed
      // backstop scans the reviews/ output dir where `**/*` correctly matches
      // every report (including architecture reports whose names lack "review").
      final review = outputResolverFor(
        'review_report_path',
        const OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
      );

      expect((review as FileSystemOutput).pathPattern, '**/*');
    });

    test('new presets expose canonical descriptions and schemas', () {
      expect(gatingFindingsCountPreset.schema, {'type': 'integer', 'minimum': 0});
      expect(gatingFindingsCountPreset.description, contains('at or above the resolved gating-severity threshold'));
      expect(gatingFindingsCountPreset.description, contains('0 means no finding of gating severity remains'));
      expect(gatingFindingsCountPreset.description, isNot(contains('Fix')));
      expect(gatingFindingsCountPreset.description, isNot(contains('Note')));
      expect(findingsCountPreset.description, 'Number of issues flagged by this review; 0 means clean.');
      expect(reviewReportPathPreset.description, contains('--output-dir'));
      expect(
        reviewReportPathPreset.description,
        matches(RegExp(r'absolute.{0,80}--output-dir', dotAll: true)),
        reason: 'the absolute form must be paired with --output-dir, not project-root-relative',
      );
      expect(
        reviewReportPathPreset.description,
        contains('project-root-relative'),
        reason: 'the description states the project-root-relative path form',
      );
      // The preset description carries no framework-specific skill name or doc
      // filename (ADR-041 / framework-neutral vocabulary).
      expect(reviewReportPathPreset.description, isNot(contains('andthen')));
      expect(reviewReportPathPreset.description, isNot(contains('review-report-location.md')));
      expect(storySpecsPreset.description, contains('foreach controller'));
      expect(
        outputResolverFor('gating_findings_count', const OutputConfig(schema: 'gating_findings_count')),
        isA<InlineOutput>(),
      );
      expect(outputResolverFor('findings_count', const OutputConfig(schema: 'findings_count')), isA<InlineOutput>());
      expect(
        outputResolverFor(
          'spec_confidence',
          const OutputConfig(
            format: OutputFormat.json,
            resolverOverride: InlineOutput(schemaKey: 'spec_confidence'),
          ),
        ),
        isA<InlineOutput>(),
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
    // `narrative_text` is the deliberate exemption: a generic free-text preset
    // whose semantics live entirely in each call site's inline `description:`,
    // so it carries none of its own (framework-neutral by construction).
    const descriptionLessTextPresets = {'narrative_text'};

    test('text presets have description, no promptFragment', () {
      for (final preset in schemaPresets.values) {
        if (preset.schema['type'] != 'string') continue;
        expect(
          preset.promptFragment,
          isNull,
          reason: '"${preset.name}" is a text preset – promptFragment is dead code for text outputs.',
        );
        if (descriptionLessTextPresets.contains(preset.name)) {
          expect(
            preset.description,
            isNull,
            reason: '"${preset.name}" is the generic narrative preset – semantics live in per-site description:.',
          );
          continue;
        }
        expect(
          preset.description,
          isNotNull,
          reason: '"${preset.name}" is a text preset – description carries its canonical meaning.',
        );
        expect(preset.description, isNotEmpty, reason: preset.name);
      }
    });

    test('narrative_text is a generic, description-less text preset', () {
      final preset = schemaPresets['narrative_text']!;
      expect(preset.format, OutputFormat.text);
      expect(preset.description, isNull, reason: 'framework semantics live in per-site inline description:');
      expect(preset.promptFragment, isNull);
      expect(
        outputResolverFor('remediation_summary', const OutputConfig(schema: 'narrative_text')),
        isA<InlineOutput>(),
      );
      expect(outputResolverFor('story_result', const OutputConfig(schema: 'narrative_text')), isA<InlineOutput>());
    });

    test('preset descriptions, property descriptions, and promptFragments are framework-neutral', () {
      expectPresetsFrameworkNeutral(schemaPresets.values);
      expect(gatingFindingsCountPreset.description, contains('at or above the resolved gating-severity threshold'));
    });

    test('the neutrality guard catches vocabulary seeded into any preset surface', () {
      SchemaPreset propertyViolation(String phrase) => SchemaPreset(
        name: 'seeded_property',
        format: OutputFormat.json,
        schema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'field': {'type': 'string', 'description': phrase},
          },
        },
      );
      SchemaPreset descriptionViolation(String phrase) => SchemaPreset(
        name: 'seeded_description',
        format: OutputFormat.text,
        schema: const {'type': 'string'},
        description: phrase,
      );
      SchemaPreset promptFragmentViolation(String phrase) => SchemaPreset(
        name: 'seeded_fragment',
        format: OutputFormat.json,
        schema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'field': {'type': 'string', 'description': 'clean'},
          },
        },
        promptFragment: phrase,
      );

      // A per-property description seeded with framework vocabulary fails the
      // guard, naming the offending property.
      expect(
        () => expectPresetsFrameworkNeutral([propertyViolation('per the FIS contract')]),
        throwsA(isA<TestFailure>()),
      );
      // Every forbidden term is caught on the description and promptFragment
      // surfaces too.
      for (final term in const [
        'per the FIS contract',
        'from the PRD',
        'authored by AndThen',
        'see review-report-location.md',
      ]) {
        expect(
          () => expectPresetsFrameworkNeutral([descriptionViolation(term)]),
          throwsA(isA<TestFailure>()),
          reason: term,
        );
        expect(
          () => expectPresetsFrameworkNeutral([promptFragmentViolation(term)]),
          throwsA(isA<TestFailure>()),
          reason: term,
        );
      }

      // The real registry passes the same guard.
      expectPresetsFrameworkNeutral(schemaPresets.values);
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

  group('registry lookup', () {
    test('lookup by name returns correct preset', () {
      expect(schemaPresets['verdict'], verdictPreset);
      expect(schemaPresets['story_specs'], storySpecsPreset);
      expect(schemaPresets['gating_findings_count'], gatingFindingsCountPreset);
      expect(schemaPresets['findings_count'], findingsCountPreset);
      expect(schemaPresets['review_report_path'], reviewReportPathPreset);
      expect(schemaPresets['narrative_text'], narrativeTextPreset);
    });

    test('unknown preset name returns null', () {
      expect(schemaPresets['unknown-preset'], isNull);
    });
  });
}
