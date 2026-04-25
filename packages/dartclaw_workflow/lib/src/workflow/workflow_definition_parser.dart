import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:yaml/yaml.dart';

import 'duration_parser.dart';
import 'workflow_template_engine.dart' show WorkflowTemplateEngine;

/// Parses workflow definition YAML files into [WorkflowDefinition] objects.
class WorkflowDefinitionParser {
  /// Parses the YAML string [source] into a [WorkflowDefinition].
  ///
  /// Throws [FormatException] if the YAML is structurally invalid.
  /// Does not perform semantic validation — use [WorkflowDefinitionValidator]
  /// for that.
  WorkflowDefinition parse(String source, {String? sourcePath}) {
    final YamlMap yaml;
    try {
      final raw = loadYaml(source);
      if (raw is! YamlMap) {
        throw FormatException('Workflow YAML must be a mapping${_at(sourcePath)}.');
      }
      yaml = raw;
    } on YamlException catch (e) {
      throw FormatException('Invalid YAML${_at(sourcePath)}: ${e.message}');
    }

    _rejectRemovedExecutionMode(yaml, null, sourcePath);
    final parsedSteps = _parseSteps(yaml['steps'], sourcePath);
    final loops = [...parsedSteps.inlineLoops, ..._normalizeLegacyLoops(_parseLoops(yaml['loops']), parsedSteps.steps)];
    return WorkflowDefinition(
      name: _requireString(yaml, 'name', sourcePath),
      description: _requireString(yaml, 'description', sourcePath),
      variables: _parseVariables(yaml['variables']),
      steps: parsedSteps.steps,
      loops: loops,
      nodes: WorkflowDefinition.normalizeNodes(parsedSteps.steps, loops),
      maxTokens: yaml['maxTokens'] as int?,
      project: _optionalString(yaml, 'project', sourcePath),
      stepDefaults: _parseStepDefaults(yaml['stepDefaults'], sourcePath),
      gitStrategy: _parseGitStrategy(yaml['gitStrategy'], sourcePath),
    );
  }

  Future<WorkflowDefinition> parseFile(String path) async {
    final content = await File(path).readAsString();
    return parse(content, sourcePath: path);
  }

  String _requireString(YamlMap yaml, String key, String? sourcePath) {
    final value = yaml[key];
    if (value == null) {
      throw FormatException('Missing required field "$key"${_at(sourcePath)}.');
    }
    if (value is! String) {
      throw FormatException('Field "$key" must be a string${_at(sourcePath)}.');
    }
    if (value.isEmpty) {
      throw FormatException('Field "$key" must not be empty${_at(sourcePath)}.');
    }
    return value;
  }

  String? _optionalString(YamlMap yaml, String key, String? sourcePath) {
    final value = yaml[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('Field "$key" must be a string${_at(sourcePath)}.');
    }
    return value;
  }

  Map<String, WorkflowVariable> _parseVariables(Object? raw) {
    if (raw is! YamlMap) return const {};
    return {for (final entry in raw.entries) entry.key as String: _parseVariable(entry.value)};
  }

  WorkflowVariable _parseVariable(Object? raw) {
    if (raw is! YamlMap) return const WorkflowVariable();
    return WorkflowVariable(
      required: (raw['required'] as bool?) ?? true,
      description: (raw['description'] as String?) ?? '',
      defaultValue: raw['default'] as String?,
    );
  }

  _ParsedSteps _parseSteps(Object? raw, String? sourcePath) {
    if (raw == null) {
      throw FormatException('Missing required field "steps"${_at(sourcePath)}.');
    }
    if (raw is! YamlList) {
      throw FormatException('Field "steps" must be a list${_at(sourcePath)}.');
    }
    if (raw.isEmpty) {
      throw FormatException('Field "steps" must not be empty${_at(sourcePath)}.');
    }
    final steps = <WorkflowStep>[];
    final inlineLoops = <WorkflowLoop>[];
    for (final entry in raw) {
      if (entry is! YamlMap) {
        throw FormatException('Each step must be a mapping${_at(sourcePath)}.');
      }
      if (_isInlineLoopStep(entry)) {
        final parsedLoop = _parseInlineLoopStep(entry, sourcePath);
        inlineLoops.add(parsedLoop.loop);
        steps.addAll(parsedLoop.steps);
        if (parsedLoop.finalizerStep != null) {
          steps.add(parsedLoop.finalizerStep!);
        }
      } else if (_isInlineForeachStep(entry)) {
        final parsedForeach = _parseInlineForeachStep(entry, sourcePath);
        steps.add(parsedForeach.controller);
        steps.addAll(parsedForeach.childSteps);
      } else {
        steps.add(_parseStep(entry, sourcePath));
      }
    }
    return _ParsedSteps(steps: steps, inlineLoops: inlineLoops);
  }

  bool _isInlineLoopStep(YamlMap raw) => (raw['type'] as String?) == 'loop';

  bool _isInlineForeachStep(YamlMap raw) => (raw['type'] as String?) == 'foreach';

  _ParsedInlineForeachStep _parseInlineForeachStep(YamlMap raw, String? sourcePath) {
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException('Foreach step must have a non-empty "id" field${_at(sourcePath)}.');
    }
    final name = raw['name'];
    if (name == null || name is! String || name.isEmpty) {
      throw FormatException('Foreach "$id" must have a non-empty "name" field${_at(sourcePath)}.');
    }
    final mapOver = (raw['map_over'] ?? raw['mapOver']) as String?;
    if (mapOver == null || mapOver.isEmpty) {
      throw FormatException('Foreach "$id" must specify "map_over"${_at(sourcePath)}.');
    }
    final childStepsRaw = raw['steps'];
    if (childStepsRaw is! YamlList || childStepsRaw.isEmpty) {
      throw FormatException('Foreach "$id" must include a non-empty "steps" list${_at(sourcePath)}.');
    }
    final childSteps = <WorkflowStep>[];
    for (final childRaw in childStepsRaw) {
      if (childRaw is! YamlMap) {
        throw FormatException('Foreach "$id" step entries must be mappings${_at(sourcePath)}.');
      }
      if (_isInlineLoopStep(childRaw) || _isInlineForeachStep(childRaw)) {
        throw FormatException('Foreach "$id" cannot contain nested loops or foreach steps${_at(sourcePath)}.');
      }
      childSteps.add(_parseStep(childRaw, sourcePath));
    }
    final maxParallel = _parseMaxParallel(raw['max_parallel'] ?? raw['maxParallel'], id, sourcePath);
    final maxItems = (raw['max_items'] ?? raw['maxItems']) as int? ?? 20;
    final mapAlias = _parseMapAlias(raw['as'] ?? raw['mapAlias'] ?? raw['map_alias'], id, sourcePath);
    final controller = WorkflowStep(
      id: id,
      name: name,
      type: 'foreach',
      mapOver: mapOver,
      maxParallel: maxParallel,
      maxItems: maxItems,
      project: raw['project'] as String?,
      contextInputs: _parseStringList(raw['contextInputs']),
      contextOutputs: _parseStringList(raw['contextOutputs']),
      foreachSteps: childSteps.map((s) => s.id).toList(growable: false),
      mapAlias: mapAlias,
      workflowVariables: _parseStringList(raw['workflow_variables'] ?? raw['workflowVariables']),
    );
    return _ParsedInlineForeachStep(controller: controller, childSteps: childSteps);
  }

  _ParsedInlineLoopStep _parseInlineLoopStep(YamlMap raw, String? sourcePath) {
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException('Inline loop step must have a non-empty "id" field${_at(sourcePath)}.');
    }

    final name = raw['name'];
    if (name == null || name is! String || name.isEmpty) {
      throw FormatException('Inline loop "$id" must have a non-empty "name" field${_at(sourcePath)}.');
    }

    final maxIterations = raw['maxIterations'];
    if (maxIterations == null || maxIterations is! int || maxIterations <= 0) {
      throw FormatException('Inline loop "$id" must have integer maxIterations > 0${_at(sourcePath)}.');
    }

    final exitGate = raw['exitGate'];
    if (exitGate == null || exitGate is! String || exitGate.isEmpty) {
      throw FormatException('Inline loop "$id" must have a non-empty "exitGate"${_at(sourcePath)}.');
    }

    final loopStepsRaw = raw['steps'];
    if (loopStepsRaw is! YamlList || loopStepsRaw.isEmpty) {
      throw FormatException('Inline loop "$id" must include a non-empty "steps" list${_at(sourcePath)}.');
    }

    final loopSteps = <WorkflowStep>[];
    for (final loopStepRaw in loopStepsRaw) {
      if (loopStepRaw is! YamlMap) {
        throw FormatException('Inline loop "$id" step entries must be mappings${_at(sourcePath)}.');
      }
      if (_isInlineLoopStep(loopStepRaw)) {
        throw FormatException('Inline loop "$id" cannot contain nested inline loops${_at(sourcePath)}.');
      }
      loopSteps.add(_parseStep(loopStepRaw, sourcePath));
    }

    String? finallyStepId;
    WorkflowStep? finalizerStep;
    final finallyRaw = raw['finally'];
    if (finallyRaw is String && finallyRaw.isNotEmpty) {
      finallyStepId = finallyRaw;
    } else if (finallyRaw is YamlMap) {
      if (_isInlineLoopStep(finallyRaw)) {
        throw FormatException('Inline loop "$id" finalizer cannot be a loop${_at(sourcePath)}.');
      }
      finalizerStep = _parseStep(finallyRaw, sourcePath);
      finallyStepId = finalizerStep.id;
    } else if (finallyRaw != null) {
      throw FormatException(
        'Inline loop "$id": "finally" must be a step ID string or a step mapping${_at(sourcePath)}.',
      );
    }

    return _ParsedInlineLoopStep(
      loop: WorkflowLoop(
        id: id,
        steps: loopSteps.map((step) => step.id).toList(growable: false),
        maxIterations: maxIterations,
        entryGate: raw['entryGate'] as String?,
        exitGate: exitGate,
        finally_: finallyStepId,
      ),
      steps: loopSteps,
      finalizerStep: finalizerStep,
    );
  }

  WorkflowStep _parseStep(YamlMap raw, String? sourcePath) {
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException('Each step must have a non-empty "id" field${_at(sourcePath)}.');
    }
    _rejectRemovedExecutionMode(raw, id, sourcePath);
    final name = raw['name'];
    if (name == null || name is! String || name.isEmpty) {
      throw FormatException('Step "$id" must have a non-empty "name" field${_at(sourcePath)}.');
    }
    // Parse skill field (optional — skill-aware steps may omit prompt).
    final skill = raw['skill'] as String?;

    // Parse prompt — optional when skill is present.
    // Accepts: List<String> (S02 canonical), String (legacy, normalized to
    // single-element list), or null (when skill is present).
    final promptRaw = raw['prompt'];
    final List<String>? prompts;
    if (promptRaw == null) {
      prompts = null;
    } else if (promptRaw is String) {
      if (promptRaw.isEmpty) {
        throw FormatException('Step "$id" must have a non-empty "prompt" field${_at(sourcePath)}.');
      }
      prompts = [promptRaw];
    } else if (promptRaw is YamlList) {
      if (promptRaw.isEmpty) {
        throw FormatException('Step "$id": "prompt" list must not be empty${_at(sourcePath)}.');
      }
      final castedPrompts = <String>[];
      for (final item in promptRaw) {
        if (item is! String || item.isEmpty) {
          throw FormatException('Step "$id": each prompt in the list must be a non-empty string${_at(sourcePath)}.');
        }
        castedPrompts.add(item);
      }
      prompts = castedPrompts;
    } else {
      throw FormatException('Step "$id": "prompt" must be a string or list of strings${_at(sourcePath)}.');
    }

    // Infer step type early so we can relax prompt requirements for hybrid types.
    final stepType = (raw['type'] as String?) ?? 'research';
    final typeAuthored = raw.containsKey('type');

    // Reject no-skill + no-prompt at parse time, except for bash/approval steps
    // which do not need an agent prompt, and foreach controllers which are pure
    // orchestration containers (their child steps have the prompts).
    if (skill == null && (prompts == null || prompts.isEmpty)) {
      if (stepType != 'bash' && stepType != 'approval' && stepType != 'foreach') {
        throw FormatException('Step "$id" must have either "prompt" or "skill" (or both)${_at(sourcePath)}.');
      }
    }

    final reviewRaw = raw['review'] as String?;
    final review = reviewRaw != null
        ? (StepReviewMode.fromYaml(reviewRaw) ??
              (throw FormatException('Step "$id": unknown review mode "$reviewRaw"${_at(sourcePath)}.')))
        : StepReviewMode.codingOnly;

    final timeoutRaw = raw['timeout'] ?? raw['timeoutSeconds'];
    int? timeoutSeconds;
    if (timeoutRaw != null) {
      if (timeoutRaw is String) {
        timeoutSeconds = parseDuration(timeoutRaw).inSeconds;
      } else if (timeoutRaw is int) {
        timeoutSeconds = timeoutRaw;
      }
    }

    final extractionRaw = raw['extraction'];
    ExtractionConfig? extraction;
    if (extractionRaw is YamlMap) {
      extraction = ExtractionConfig(
        type: ExtractionType.values.byName(extractionRaw['type'] as String),
        pattern: extractionRaw['pattern'] as String,
      );
    }

    // Parse outputs map (new 0.15.1 syntax).
    final outputsRaw = raw['outputs'];
    Map<String, OutputConfig>? outputs;
    if (outputsRaw is YamlMap) {
      outputs = {};
      for (final entry in outputsRaw.entries) {
        final key = entry.key as String;
        final value = entry.value;
        if (value is YamlMap) {
          final formatRaw = value['format'] as String?;
          final format = formatRaw != null
              ? (OutputFormat.fromYaml(formatRaw) ??
                    (throw FormatException('Step "$id" output "$key": unknown format "$formatRaw"${_at(sourcePath)}.')))
              : OutputFormat.text;
          final schema = _parseSchema(value['schema']);
          final outputSource = value['source'] as String?;
          final outputModeRaw = (value['outputMode'] ?? value['output_mode']) as String?;
          final outputMode = outputModeRaw != null
              ? (OutputMode.fromYaml(outputModeRaw) ??
                    (throw FormatException(
                      'Step "$id" output "$key": unknown outputMode "$outputModeRaw"${_at(sourcePath)}.',
                    )))
              : (format == OutputFormat.json && schema != null ? OutputMode.structured : OutputMode.prompt);
          final description = value['description'] as String?;
          outputs[key] = OutputConfig(
            format: format,
            schema: schema,
            source: outputSource,
            outputMode: outputMode,
            description: description,
          );
        } else {
          // Shorthand: `key: json` or `key: lines`
          final format = OutputFormat.fromYaml(value.toString());
          outputs[key] = OutputConfig(format: format ?? OutputFormat.text);
        }
      }
    }

    // Parse map step fields. Accept both snake_case (primary) and camelCase (alias).
    final mapOver = (raw['map_over'] ?? raw['mapOver']) as String?;
    final maxParallel = _parseMaxParallel(raw['max_parallel'] ?? raw['maxParallel'], id, sourcePath);
    final maxItems = (raw['max_items'] ?? raw['maxItems']) as int? ?? 20;
    final foreachStepsRaw = raw['foreach_steps'] ?? raw['foreachSteps'];
    final foreachSteps = foreachStepsRaw is YamlList
        ? foreachStepsRaw.cast<String>().toList(growable: false)
        : (foreachStepsRaw as List?)?.cast<String>();
    // `as:` is the primary spelling; `mapAlias:` / `map_alias:` also accepted for
    // round-trip compatibility with the JSON model.
    final mapAlias = _parseMapAlias(raw['as'] ?? raw['mapAlias'] ?? raw['map_alias'], id, sourcePath);

    return WorkflowStep(
      id: id,
      name: name,
      skill: skill,
      prompts: prompts,
      type: stepType,
      typeAuthored: typeAuthored,
      project: raw['project'] as String?,
      provider: raw['provider'] as String?,
      model: raw['model'] as String?,
      effort: raw['effort'] as String?,
      timeoutSeconds: timeoutSeconds,
      review: review,
      parallel: (raw['parallel'] as bool?) ?? false,
      gate: raw['gate'] as String?,
      entryGate: raw['entryGate'] as String?,
      contextInputs: _parseStringList(raw['contextInputs']),
      contextOutputs: _parseStringList(raw['contextOutputs']),
      extraction: extraction,
      outputs: outputs,
      maxTokens: raw['maxTokens'] as int?,
      maxCostUsd: _parseDouble(raw['maxCostUsd']),
      maxRetries: raw['maxRetries'] as int?,
      allowedTools: _parseOptionalStringList(raw['allowedTools']),
      mapOver: mapOver,
      maxParallel: maxParallel,
      maxItems: maxItems,
      foreachSteps: foreachSteps,
      mapAlias: mapAlias,
      continueSession: _parseContinueSession(raw['continueSession'] ?? raw['continue_session'], id, sourcePath),
      onError: (raw['onError'] ?? raw['on_error']) as String?,
      workdir: raw['workdir'] as String?,
      onFailure: _parseOnFailure(raw['onFailure'] ?? raw['on_failure'], id, sourcePath),
      emitsOwnOutcome: _parseEmitsOwnOutcome(raw['emitsOwnOutcome'] ?? raw['emits_own_outcome'], id, sourcePath),
      autoFrameContext: _parseAutoFrameContext(raw['auto_frame_context'] ?? raw['autoFrameContext'], id, sourcePath),
      workflowVariables: _parseStringList(raw['workflow_variables'] ?? raw['workflowVariables']),
    );
  }

  OnFailurePolicy _parseOnFailure(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return OnFailurePolicy.fail;
    if (raw is! String) {
      throw FormatException('Step "$stepId": "onFailure" must be a string${_at(sourcePath)}.');
    }
    final policy = OnFailurePolicy.fromYaml(raw);
    if (policy == null) {
      throw FormatException(
        'Step "$stepId": unknown onFailure policy "$raw" '
        '(expected fail, continue, retry, or pause)${_at(sourcePath)}.',
      );
    }
    return policy;
  }

  bool _parseEmitsOwnOutcome(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return false;
    if (raw is bool) return raw;
    throw FormatException('Step "$stepId": "emitsOwnOutcome" must be a boolean (true or false)${_at(sourcePath)}.');
  }

  bool _parseAutoFrameContext(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return true;
    if (raw is bool) return raw;
    throw FormatException('Step "$stepId": "auto_frame_context" must be a boolean (true or false)${_at(sourcePath)}.');
  }

  String? _parseContinueSession(Object? raw, String stepId, String? sourcePath) {
    if (raw == null || raw == false) return null;
    if (raw == true) return '@previous';
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    throw FormatException(
      'Step "$stepId": "continueSession" must be true or a non-empty step ID string${_at(sourcePath)}.',
    );
  }

  /// Parses the `as:` loop variable name for a map/foreach controller.
  ///
  /// Enforces identifier format and rejects reserved template prefixes. Cross-
  /// field rules (e.g. "as: only allowed on map/foreach controllers") live in
  /// the validator so the parser stays focused on shape.
  static final _mapAliasPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  String? _parseMapAlias(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! String) {
      throw FormatException('Step "$stepId": "as" must be a string identifier${_at(sourcePath)}.');
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Step "$stepId": "as" must not be empty${_at(sourcePath)}.');
    }
    if (!_mapAliasPattern.hasMatch(trimmed)) {
      throw FormatException(
        'Step "$stepId": "as" must match [A-Za-z_][A-Za-z0-9_]* '
        '(got "$trimmed")${_at(sourcePath)}.',
      );
    }
    if (WorkflowTemplateEngine.reservedMapAliases.contains(trimmed)) {
      throw FormatException(
        'Step "$stepId": "as: $trimmed" is reserved — pick a different identifier${_at(sourcePath)}.',
      );
    }
    return trimmed;
  }

  void _rejectRemovedExecutionMode(YamlMap raw, String? stepId, String? sourcePath) {
    if (!raw.containsKey('executionMode') && !raw.containsKey('execution_mode')) {
      return;
    }
    final prefix = stepId == null ? 'Workflow' : 'Step "$stepId"';
    throw FormatException(
      '$prefix: executionMode was removed in 0.16.4; workflow steps now always use one-shot execution${_at(sourcePath)}.',
    );
  }

  /// Parses the `max_parallel` value from YAML.
  ///
  /// Accepts int (concurrency limit), String "unlimited", or String template.
  /// Returns null if absent.
  Object? _parseMaxParallel(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is String) return raw;
    throw FormatException(
      'Step "$stepId": "max_parallel" must be an integer or string '
      '(e.g., 3, "unlimited", or a template like "{{MAX_PARALLEL}}")${_at(sourcePath)}.',
    );
  }

  /// Parses a schema value: String (preset name), Map (inline schema), or null.
  Object? _parseSchema(Object? raw) {
    if (raw == null) return null;
    if (raw is String) return raw; // Preset name.
    if (raw is YamlMap) return _yamlToMap(raw); // Inline JSON Schema.
    return null;
  }

  /// Deep-converts a [YamlMap] to a plain `Map<String, dynamic>`.
  Map<String, dynamic> _yamlToMap(YamlMap yaml) {
    return {for (final entry in yaml.entries) entry.key.toString(): _yamlToValue(entry.value)};
  }

  dynamic _yamlToValue(Object? value) {
    if (value is YamlMap) return _yamlToMap(value);
    if (value is YamlList) return value.map(_yamlToValue).toList();
    return value;
  }

  List<WorkflowLoop> _parseLoops(Object? raw) {
    if (raw is! YamlList) return const [];
    return raw.map((l) => _parseLoop(l as YamlMap)).toList(growable: false);
  }

  WorkflowLoop _parseLoop(YamlMap raw) {
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException('Legacy loop entry must have a non-empty "id" field.');
    }
    final maxIterations = raw['maxIterations'];
    if (maxIterations == null || maxIterations is! int || maxIterations <= 0) {
      throw FormatException('Legacy loop "$id" must have integer "maxIterations" > 0.');
    }
    return WorkflowLoop(
      id: id,
      steps: _parseStringList(raw['steps']),
      maxIterations: maxIterations,
      entryGate: raw['entryGate'] as String?,
      exitGate: (raw['exitGate'] as String?) ?? '',
      finally_: raw['finally'] as String?,
    );
  }

  WorkflowGitStrategy? _parseGitStrategy(Object? raw, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! YamlMap) {
      throw FormatException('Field "gitStrategy" must be a mapping${_at(sourcePath)}.');
    }
    if (raw.containsKey('finalReview')) {
      throw FormatException(
        'Field "gitStrategy.finalReview" was removed: it had no runtime behavior. '
        'Remove it from your workflow definition${_at(sourcePath)}.',
      );
    }
    if (raw.containsKey('cleanup')) {
      throw FormatException(
        'Field "gitStrategy.cleanup" was removed: it had no runtime behavior. '
        'Remove it from your workflow definition${_at(sourcePath)}.',
      );
    }

    final publishRaw = raw['publish'];
    WorkflowGitPublishStrategy? publish;
    if (publishRaw != null) {
      if (publishRaw is! YamlMap) {
        throw FormatException('Field "gitStrategy.publish" must be a mapping${_at(sourcePath)}.');
      }
      publish = WorkflowGitPublishStrategy(enabled: publishRaw['enabled'] as bool?);
    }

    final artifactsRaw = raw['artifacts'];
    WorkflowGitArtifactsStrategy? artifacts;
    if (artifactsRaw != null) {
      if (artifactsRaw is! YamlMap) {
        throw FormatException('Field "gitStrategy.artifacts" must be a mapping${_at(sourcePath)}.');
      }
      artifacts = WorkflowGitArtifactsStrategy(
        commit: artifactsRaw['commit'] as bool?,
        commitMessage: (artifactsRaw['commitMessage'] ?? artifactsRaw['commit_message']) as String?,
        project: artifactsRaw['project'] as String?,
      );
    }

    final worktreeRaw = raw['worktree'];
    WorkflowGitWorktreeStrategy? worktree;
    WorkflowGitExternalArtifactMount? nestedMount;
    if (worktreeRaw != null) {
      if (worktreeRaw is String) {
        worktree = WorkflowGitWorktreeStrategy(mode: worktreeRaw);
      } else if (worktreeRaw is YamlMap) {
        nestedMount = _parseExternalArtifactMount(
          worktreeRaw['externalArtifactMount'] ?? worktreeRaw['external_artifact_mount'],
          sourcePath,
          'gitStrategy.worktree.externalArtifactMount',
        );
        worktree = WorkflowGitWorktreeStrategy(
          mode: worktreeRaw['mode'] as String?,
          externalArtifactMount: nestedMount,
        );
      } else {
        throw FormatException('Field "gitStrategy.worktree" must be a string or mapping${_at(sourcePath)}.');
      }
    }

    final flatMountRaw = raw['externalArtifactMount'] ?? raw['external_artifact_mount'];
    if (flatMountRaw != null && nestedMount != null) {
      throw FormatException(
        'Field "gitStrategy.externalArtifactMount" was moved to '
        '"gitStrategy.worktree.externalArtifactMount"; remove the deprecated '
        'flat-level declaration${_at(sourcePath)}.',
      );
    }
    final flatMount = _parseExternalArtifactMount(flatMountRaw, sourcePath, 'gitStrategy.externalArtifactMount');
    final legacyExternalArtifactMountLocation = flatMount != null;
    worktree ??= WorkflowGitWorktreeStrategy();
    if (flatMount != null) {
      worktree = WorkflowGitWorktreeStrategy(mode: worktree.mode, externalArtifactMount: flatMount);
    }

    final rawMergeResolve = raw['merge_resolve'] ?? raw['mergeResolve'];
    return WorkflowGitStrategy(
      bootstrap: raw['bootstrap'] as bool?,
      worktree: worktree,
      promotion: raw['promotion'] as String?,
      publish: publish,
      artifacts: artifacts,
      legacyExternalArtifactMountLocation: legacyExternalArtifactMountLocation,
      mergeResolve: rawMergeResolve != null ? MergeResolveConfig.fromJson(rawMergeResolve) : null,
    );
  }

  WorkflowGitExternalArtifactMount? _parseExternalArtifactMount(Object? raw, String? sourcePath, String fieldPath) {
    if (raw == null) return null;
    if (raw is! YamlMap) {
      throw FormatException('Field "$fieldPath" must be a mapping${_at(sourcePath)}.');
    }
    final fromProject = raw['fromProject'] ?? raw['from_project'];
    if (fromProject is! String || fromProject.trim().isEmpty) {
      throw FormatException('Field "$fieldPath.fromProject" is required${_at(sourcePath)}.');
    }
    final mode = (raw['mode'] as String?) ?? 'per-story-copy';
    if (mode != 'per-story-copy' && mode != 'bind-mount') {
      throw FormatException(
        'Field "$fieldPath.mode" must be "per-story-copy" or '
        '"bind-mount" (got "$mode")${_at(sourcePath)}.',
      );
    }
    return WorkflowGitExternalArtifactMount(
      mode: mode,
      fromProject: fromProject,
      source: raw['source'] as String?,
      fromPath: (raw['fromPath'] ?? raw['from_path']) as String?,
      toPath: (raw['toPath'] ?? raw['to_path']) as String?,
      readonly: raw['readonly'] as bool?,
    );
  }

  List<WorkflowLoop> _normalizeLegacyLoops(List<WorkflowLoop> loops, List<WorkflowStep> steps) {
    if (loops.length <= 1) return loops;
    final indexByStepId = <String, int>{for (var i = 0; i < steps.length; i++) steps[i].id: i};
    final decorated = loops
        .asMap()
        .entries
        .map((entry) {
          final originalIndex = entry.key;
          final loop = entry.value;
          final firstStepId = loop.steps.firstOrNull;
          final authoredIndex = firstStepId != null
              ? (indexByStepId[firstStepId] ?? steps.length + originalIndex)
              : steps.length + originalIndex;
          return (loop: loop, authoredIndex: authoredIndex, originalIndex: originalIndex);
        })
        .toList(growable: false);

    decorated.sort((a, b) {
      final byAuthoredIndex = a.authoredIndex.compareTo(b.authoredIndex);
      if (byAuthoredIndex != 0) return byAuthoredIndex;
      return a.originalIndex.compareTo(b.originalIndex);
    });
    return decorated.map((entry) => entry.loop).toList(growable: false);
  }

  List<StepConfigDefault>? _parseStepDefaults(Object? raw, String? sourcePath) {
    if (raw is! YamlList) return null;
    return raw
        .map((entry) {
          if (entry is! YamlMap) {
            throw FormatException('Each stepDefaults entry must be a mapping${_at(sourcePath)}.');
          }
          final match = entry['match'];
          if (match == null || match is! String || match.isEmpty) {
            throw FormatException('Each stepDefaults entry must have a non-empty "match" field${_at(sourcePath)}.');
          }
          return StepConfigDefault(
            match: match,
            provider: entry['provider'] as String?,
            model: entry['model'] as String?,
            effort: entry['effort'] as String?,
            maxTokens: entry['maxTokens'] as int?,
            maxCostUsd: _parseDouble(entry['maxCostUsd']),
            maxRetries: entry['maxRetries'] as int?,
            allowedTools: _parseOptionalStringList(entry['allowedTools']),
          );
        })
        .toList(growable: false);
  }

  List<String> _parseStringList(Object? raw) {
    if (raw is! YamlList) return const [];
    return raw.cast<String>().toList(growable: false);
  }

  List<String>? _parseOptionalStringList(Object? raw) {
    if (raw is! YamlList) return null;
    return raw.cast<String>().toList(growable: false);
  }

  /// Parses a numeric value as [double], accepting both int and double YAML values.
  ///
  /// YAML parses bare numbers like `2` as int, not double. This normalizes them.
  double? _parseDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    return null;
  }

  String _at(String? sourcePath) => sourcePath != null ? ' in "$sourcePath"' : '';
}

class _ParsedSteps {
  final List<WorkflowStep> steps;
  final List<WorkflowLoop> inlineLoops;

  const _ParsedSteps({required this.steps, required this.inlineLoops});
}

class _ParsedInlineLoopStep {
  final WorkflowLoop loop;
  final List<WorkflowStep> steps;
  final WorkflowStep? finalizerStep;

  const _ParsedInlineLoopStep({required this.loop, required this.steps, this.finalizerStep});
}

class _ParsedInlineForeachStep {
  final WorkflowStep controller;
  final List<WorkflowStep> childSteps;

  const _ParsedInlineForeachStep({required this.controller, required this.childSteps});
}
