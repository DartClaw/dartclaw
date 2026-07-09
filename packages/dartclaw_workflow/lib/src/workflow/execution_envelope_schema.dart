import 'package:logging/logging.dart';

import 'output_resolver.dart';
import 'prompt_augmenter.dart' show PromptAugmenter;
import 'review_scoring_fragment.dart';
import 'schema_presets.dart' show outputResolverFor, schemaPresets;
import 'workflow_definition.dart' show OutputConfig, OutputFormat, OutputMode, WorkflowStep, WorkflowTaskType;
import 'workflow_output_contract.dart';

/// Property names whose value is a review-scoring count; their finalizer
/// description carries the severity-threshold scoring rule.
const Set<String> _reviewScoringPresetNames = {'gating_findings_count', 'verdict'};

final _log = Logger('ExecutionEnvelopeSchema');

/// Result of applying the strict deep-close transform to a declared schema.
typedef DeepClosedSchema = ({Map<String, dynamic>? schema, bool changed});

/// Whether [step] finishes through the structured finalization envelope.
///
/// Eligible: a workflow-owned agent step whose declared outputs need model
/// claims. Excluded: deterministic/controller steps (non-agent task types),
/// outcome-only steps (no model-derived declared outputs — they keep the inline
/// `<step-outcome>` tag as their designed channel), and outputs opted out via
/// `outputMode: prompt`. `setValue`, `source`, and canonical `*_source` defaults
/// stay host-owned and never count toward eligibility.
bool stepNeedsFinalizer(WorkflowStep step, Map<String, OutputConfig>? effectiveOutputs) {
  if (step.taskType != WorkflowTaskType.agent) return false;
  return modelDerivedFinalizerKeys(step, effectiveOutputs).isNotEmpty;
}

/// Ordered declared-output keys the finalizer must claim for [step].
///
/// This is the exact set the execution envelope covers, so it is also the set
/// `PromptAugmenter` excludes from the main-prompt output contract. Callers must
/// gate on [stepNeedsFinalizer] first — this accessor does **not** check
/// `taskType`, so a deterministic step declaring a model-derived output would
/// otherwise report its key as covered.
List<String> modelDerivedFinalizerKeys(WorkflowStep step, Map<String, OutputConfig>? effectiveOutputs) {
  if (effectiveOutputs == null || effectiveOutputs.isEmpty) return const [];
  return [
    for (final entry in effectiveOutputs.entries)
      if (isModelDerivedFinalizerOutput(entry.key, entry.value)) entry.key,
  ];
}

/// Whether the output [key]/[config] is a model-derived claim the finalizer
/// supplies, as opposed to a host-owned value the engine resolves itself.
///
/// Covered means claimable: a key only counts when the envelope can actually
/// carry it, so the covered set and the built envelope schema stay exact
/// mirrors and no key is left instructed nowhere.
bool isModelDerivedFinalizerOutput(String key, OutputConfig config) {
  if (config.hasSetValue) return false; // literal write — host-owned
  if (config.source != null) return false; // task-metadata read — host-owned
  if (key.endsWith('_source')) return false; // canonical `synthesized` default — host-owned
  if (_isPromptOptOut(config)) return false; // explicit user-facing finalizer opt-out
  final resolver = outputResolverFor(key, config);
  if (resolver is FileSystemOutput) return true; // nullable path claim — always schemable
  if (resolver is! InlineOutput) return false;
  // A schema-less `format: json` output has no envelope representation
  // (mirrors _envelopeOutputSchema returning null), so counting it as covered
  // would drop it from the main prompt without an envelope slot — it keeps the
  // legacy main-prompt contract instead.
  if (config.format == OutputFormat.json &&
      config.inlineSchema == null &&
      schemaPresets[config.presetName]?.schema == null) {
    return false;
  }
  return true;
}

/// A JSON output whose author explicitly pinned `outputMode: prompt` opts that
/// output out of finalization (the preserved user-facing opt-out). For JSON
/// outputs with a schema the parser defaults to `structured`, so `prompt` there
/// is a deliberate choice; non-JSON outputs default to `prompt` and are not
/// treated as an opt-out.
bool _isPromptOptOut(OutputConfig config) =>
    config.format == OutputFormat.json && config.hasSchema && config.outputMode == OutputMode.prompt;

/// Builds the strict structured execution-envelope schema for a finalizer step.
///
/// Shape: a fully-closed outer object with required top-level [outputs]
/// (`executionEnvelopeOutputsKey`) and, unless the step opts out with
/// `emitsOwnOutcome: true`, required [step_outcome]
/// (`executionEnvelopeStepOutcomeKey`). Every nested object carries
/// `additionalProperties: false` and a complete `required` list.
///
/// The `outputs` subobject contains only model-derived keys (narrative, inline,
/// and filesystem-claim); host-owned outputs (`setValue`, `source`, canonical
/// `*_source` defaults) are excluded. Path-claim keys are declared nullable so a
/// no-claim `null` survives strict mode and the host's glob / reviews-dir
/// fallbacks stay reachable. Returns null when the step has no model-derived
/// outputs (nothing for the finalizer to claim).
Map<String, dynamic>? buildExecutionEnvelopeSchema(
  WorkflowStep step,
  Map<String, OutputConfig>? effectiveOutputs, {
  String gatingSeverity = defaultGatingSeverity,
}) {
  if (effectiveOutputs == null || effectiveOutputs.isEmpty) return null;

  final outputsProperties = <String, dynamic>{};
  final outputsRequired = <String>[];
  for (final entry in effectiveOutputs.entries) {
    if (!isModelDerivedFinalizerOutput(entry.key, entry.value)) continue;
    // Non-null by the covered-iff-claimable predicate above; a null here means
    // the mirror broke and must fail loudly, not silently drop the key.
    final schema = _envelopeOutputSchema(entry.key, entry.value)!;
    outputsProperties[entry.key] = _withFinalizerDescription(schema, entry.value, gatingSeverity);
    outputsRequired.add(entry.key);
  }
  if (outputsProperties.isEmpty) return null;

  final properties = <String, dynamic>{
    executionEnvelopeOutputsKey: {
      'type': 'object',
      'additionalProperties': false,
      'required': outputsRequired,
      'properties': outputsProperties,
    },
  };
  final required = <String>[executionEnvelopeOutputsKey];
  if (!step.emitsOwnOutcome) {
    properties[executionEnvelopeStepOutcomeKey] = stepOutcomeEnvelopeSchema();
    required.add(executionEnvelopeStepOutcomeKey);
  }
  return {'type': 'object', 'additionalProperties': false, 'required': required, 'properties': properties};
}

/// Strict sub-schema for the engine-owned `step_outcome` object.
Map<String, dynamic> stepOutcomeEnvelopeSchema() => {
  'type': 'object',
  'additionalProperties': false,
  'required': ['outcome', 'reason'],
  'properties': {
    'outcome': {
      'type': 'string',
      'enum': ['succeeded', 'failed', 'needsInput'],
      'description':
          'Semantic outcome of the work: "succeeded" when the step met its goal, '
          '"failed" when it could not, "needsInput" when a human decision or missing '
          'requirement blocks safe progress.',
    },
    'reason': {'type': 'string', 'description': 'Short justification for the chosen outcome.'},
  },
};

/// Attaches a finalizer-facing `description` to an envelope output property so
/// the descriptions and review-scoring guidance travel with the schema (a
/// single source the finalizer prompt renders from). Preserves any description
/// the declared JSON schema already carries.
Map<String, dynamic> _withFinalizerDescription(
  Map<String, dynamic> schema,
  OutputConfig config,
  String gatingSeverity,
) {
  final parts = <String>[];
  final declared = schema['description'];
  if (declared is String && declared.trim().isNotEmpty) parts.add(declared.trim());
  final effective = PromptAugmenter.effectiveDescription(config);
  if (effective != null && effective.isNotEmpty && !parts.contains(effective)) parts.add(effective);
  if (_reviewScoringPresetNames.contains(config.presetName)) {
    parts.add(reviewScoringFragmentFor(gatingSeverity).trim());
  }
  if (parts.isEmpty) return schema;
  return {...schema, 'description': parts.join('\n\n')};
}

/// Renders the no-tools finalizer turn prompt from a persisted execution-envelope
/// [schema]. Surfaces each declared output key with its description and the
/// step-outcome semantics so the model serializes its completed work into the
/// strict envelope. Returns a generic instruction when [schema] is not an
/// envelope (legacy/opt-out steps never reach this path).
String buildFinalizerPrompt(Map<String, dynamic> schema) {
  final buf = StringBuffer();
  buf.writeln('Based on your work above, produce the structured execution envelope for this step.');
  buf.writeln('Output ONLY the JSON object matching the provided schema. Do NOT use any tools.');

  final properties = schema['properties'];
  final outputs = properties is Map ? properties[executionEnvelopeOutputsKey] : null;
  final outputProperties = outputs is Map ? outputs['properties'] : null;
  if (outputProperties is Map && outputProperties.isNotEmpty) {
    buf.writeln();
    buf.writeln('## Declared Outputs');
    buf.writeln();
    buf.writeln('Populate `$executionEnvelopeOutputsKey` with exactly these keys:');
    for (final entry in outputProperties.entries) {
      final prop = entry.value;
      final desc = prop is Map ? (prop['description'] as String?)?.trim() : null;
      buf.writeln(desc == null || desc.isEmpty ? '- "${entry.key}"' : '- "${entry.key}" – $desc');
    }
  }

  final stepOutcome = properties is Map ? properties[executionEnvelopeStepOutcomeKey] : null;
  if (stepOutcome is Map) {
    final outcomeProp = stepOutcome['properties'];
    final outcomeDesc = outcomeProp is Map && outcomeProp['outcome'] is Map
        ? (outcomeProp['outcome']['description'] as String?)?.trim()
        : null;
    buf.writeln();
    buf.writeln('## Step Outcome');
    buf.writeln();
    buf.writeln(
      'Populate `$executionEnvelopeStepOutcomeKey` with `outcome` '
      '(one of `succeeded`, `failed`, `needsInput`) and a short `reason`.',
    );
    if (outcomeDesc != null && outcomeDesc.isNotEmpty) buf.writeln(outcomeDesc);
  }

  return buf.toString().trimRight();
}

Map<String, dynamic>? _envelopeOutputSchema(String key, OutputConfig config) {
  final resolver = outputResolverFor(key, config);
  if (resolver is FileSystemOutput) {
    // Path/artifact claims are candidate values the host validates. A no-claim
    // `null` must survive strict mode so the glob and reviews-dir backstops stay
    // reachable (load-bearing per packages/dartclaw_workflow/AGENTS.md).
    return resolver.listMode
        ? {
            'type': ['array', 'null'],
            'items': {'type': 'string'},
          }
        : {
            'type': ['string', 'null'],
          };
  }
  switch (config.format) {
    case OutputFormat.text:
    case OutputFormat.path:
      return {'type': 'string'};
    case OutputFormat.lines:
      return {
        'type': 'array',
        'items': {'type': 'string'},
      };
    case OutputFormat.json:
      final declared = config.inlineSchema ?? schemaPresets[config.presetName]?.schema;
      final closed = deepCloseSchema(declared);
      if (closed.changed) {
        _log.warning(
          'Output "$key": declared JSON schema was not strict-closed; applied a '
          'deep-close transform to the finalizer envelope copy only (declared schema unchanged).',
        );
      }
      return closed.schema;
  }
}

/// Deep-closes [schema] for strict provider structured output: injects
/// `additionalProperties: false` on every object, and promotes optional
/// properties to required keys whose schema also allows `null`.
///
/// Operates on a deep copy — the declared schema is never mutated. Returns the
/// transformed schema and whether any closure was needed (drives the
/// author-facing warning).
DeepClosedSchema deepCloseSchema(Map<String, dynamic>? schema) {
  if (schema == null) return (schema: null, changed: false);
  var changed = false;

  Map<String, dynamic> close(Map<String, dynamic> node) {
    final result = <String, dynamic>{...node};
    final props = node['properties'];
    if (props is Map) {
      final closedProps = <String, dynamic>{};
      for (final entry in props.entries) {
        final child = entry.value;
        closedProps[entry.key.toString()] = child is Map
            ? close(child.map((k, v) => MapEntry(k.toString(), v)))
            : child;
      }
      if (result['additionalProperties'] != false) {
        result['additionalProperties'] = false;
        changed = true;
      }
      final existingRequired = (node['required'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
      final allKeys = closedProps.keys.toSet();
      final missing = allKeys.difference(existingRequired);
      if (missing.isNotEmpty) {
        for (final key in missing) {
          closedProps[key] = _allowNull(closedProps[key]);
        }
        changed = true;
      }
      result['properties'] = closedProps;
      result['required'] = allKeys.toList();
    }
    final items = node['items'];
    if (items is Map) {
      result['items'] = close(items.map((k, v) => MapEntry(k.toString(), v)));
    }
    return result;
  }

  final closed = close(schema.map((k, v) => MapEntry(k.toString(), v)));
  return (schema: closed, changed: changed);
}

/// Widens a property schema so its declared type(s) also permit `null`.
///
/// Widening only `type` is insufficient for a value-constrained property: an
/// `enum` or `const` that omits `null` still forbids the absent-as-null value,
/// leaving the deep-closed schema unsatisfiable for an omitted optional. So an
/// `enum` gains a `null` member and a `const` widens to a two-value `enum`.
Object? _allowNull(Object? propSchema) {
  if (propSchema is! Map) return propSchema;
  final result = <String, dynamic>{...propSchema.map((k, v) => MapEntry(k.toString(), v))};
  final type = result['type'];
  if (type is String) {
    if (type != 'null') result['type'] = [type, 'null'];
  } else if (type is List) {
    if (!type.contains('null')) result['type'] = [...type, 'null'];
  }
  final enumValues = result['enum'];
  if (enumValues is List) {
    if (!enumValues.contains(null)) result['enum'] = [...enumValues, null];
  } else if (result.containsKey('const')) {
    result['enum'] = [result.remove('const'), null];
  }
  return result;
}
