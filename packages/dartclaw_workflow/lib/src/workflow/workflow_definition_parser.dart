import 'dart:io';

import 'package:yaml/yaml.dart';

import 'duration_parser.dart';
import 'output_resolver.dart';
import 'review_scoring_fragment.dart';
import 'schema_presets.dart';
import 'workflow_definition.dart';
import 'workflow_git_strategy_fields.dart';
import 'workflow_template_engine.dart' show WorkflowTemplateEngine;

/// Parses workflow definition YAML files into [WorkflowDefinition] objects.
///
/// Inherits `package:yaml`'s last-key-wins semantics on duplicate map keys:
/// a step with two `prompt:` lines or two `outputs:` blocks silently keeps
/// only the last occurrence. The validator catches duplicate step IDs but
/// does not detect intra-step duplicate keys — author tooling (formatters,
/// linters) is the practical line of defence.
class WorkflowDefinitionParser {
  static const _workflowKeys = {
    'name',
    'description',
    'variables',
    'steps',
    'maxTokens',
    'project',
    'stepDefaults',
    'gitStrategy',
  };

  static const _variableKeys = {'required', 'description', 'default'};

  static const _stepKeys = {
    'id',
    'name',
    'skill',
    'type',
    'prompt',
    'script',
    'provider',
    'model',
    'effort',
    'gatingSeverity',
    'timeout',
    'timeoutSeconds',
    'timeout_seconds',
    'parallel',
    'gate',
    'entryGate',
    'inputs',
    'outputs',
    'outputExamples',
    'maxTokens',
    'maxRetries',
    'allowedTools',
    'aggregateReviews',
    'map_over',
    'mapOver',
    'max_parallel',
    'maxParallel',
    'max_items',
    'maxItems',
    'foreach_steps',
    'foreachSteps',
    'as',
    'mapAlias',
    'map_alias',
    'continueSession',
    'continue_session',
    'onError',
    'on_error',
    'workdir',
    'onFailure',
    'on_failure',
    'emitsOwnOutcome',
    'emits_own_outcome',
    'auto_frame_context',
    'autoFrameContext',
    'workflow_variables',
    'workflowVariables',
  };

  static const _inlineForeachKeys = {
    'id',
    'name',
    'type',
    'map_over',
    'mapOver',
    'max_parallel',
    'maxParallel',
    'max_items',
    'maxItems',
    'as',
    'mapAlias',
    'map_alias',
    'gate',
    'entryGate',
    'inputs',
    'outputs',
    'outputExamples',
    'steps',
    'onFailure',
    'on_failure',
    'workflow_variables',
    'workflowVariables',
  };

  static const _inlineLoopKeys = {
    'id',
    'name',
    'type',
    'maxIterations',
    'entryGate',
    'exitGate',
    'steps',
    'finally',
    'onMaxIterations',
  };

  static const _outputConfigKeys = {
    'format',
    'schema',
    'source',
    'resolver',
    'outputMode',
    'output_mode',
    'description',
    'setValue',
    'set_value',
    'pathPattern',
    'path_pattern',
    'listMode',
    'list_mode',
    'preferPatterns',
    'prefer_patterns',
  };

  static const _outputResolverKeys = {'kind', 'pathPattern', 'listMode', 'preferPatterns'};

  static const _stepDefaultKeys = {
    'match',
    'provider',
    'model',
    'effort',
    'gatingSeverity',
    'maxTokens',
    'maxRetries',
    'timeout_seconds',
    'timeoutSeconds',
    'allowedTools',
  };

  static const _gitStrategyKeys = {
    'integrationBranch',
    'integration_branch',
    'bootstrap',
    'worktree',
    'promotion',
    'publish',
    'cleanup',
    'artifacts',
    'merge_resolve',
    'mergeResolve',
  };

  static const _gitPublishKeys = {'enabled'};
  static const _gitCleanupKeys = {'enabled'};
  static const _gitArtifactsKeys = {'commit', 'commitMessage', 'commit_message', 'project'};
  static const _gitWorktreeKeys = {'mode', 'externalArtifactMount', 'external_artifact_mount'};

  static const _externalArtifactMountKeys = {
    'mode',
    'fromProject',
    'from_project',
    'source',
    'fromPath',
    'from_path',
    'toPath',
    'to_path',
    'readonly',
  };

  /// Parses the YAML string [source] into a [WorkflowDefinition].
  ///
  /// Throws [FormatException] if the YAML is structurally invalid.
  /// Does not perform semantic validation – use [WorkflowDefinitionValidator]
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

    _rejectUnknownFields(yaml, _workflowKeys, 'workflow', sourcePath);
    final parsedSteps = _parseSteps(yaml['steps'], sourcePath);
    return WorkflowDefinition(
      name: _requireString(yaml, 'name', sourcePath),
      description: _requireString(yaml, 'description', sourcePath),
      variables: _parseVariables(yaml['variables'], sourcePath),
      steps: parsedSteps.steps,
      loops: parsedSteps.inlineLoops,
      nodes: WorkflowDefinition.normalizeNodes(parsedSteps.steps, parsedSteps.inlineLoops),
      maxTokens: _optionalInt(yaml['maxTokens'], 'maxTokens', sourcePath),
      project: _optionalString(yaml, 'project', sourcePath),
      stepDefaults: _parseStepDefaults(yaml['stepDefaults'], sourcePath),
      gitStrategy: _parseGitStrategy(yaml['gitStrategy'], sourcePath),
    );
  }

  Future<WorkflowDefinition> parseFile(String path) async {
    final content = await File(path).readAsString();
    return parse(content, sourcePath: path);
  }

  void _rejectUnknownFields(YamlMap raw, Set<String> knownKeys, String blockLabel, String? sourcePath) {
    for (final key in raw.keys) {
      final field = key.toString();
      if (knownKeys.contains(field)) continue;
      throw FormatException('Unknown field "$field" under $blockLabel${_at(sourcePath)}.');
    }
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

  Map<String, WorkflowVariable> _parseVariables(Object? raw, String? sourcePath) {
    if (raw == null) return const {};
    if (raw is! YamlMap) {
      throw FormatException('Field "variables" must be a mapping${_at(sourcePath)}.');
    }
    return {
      for (final entry in raw.entries)
        _requireYamlStringKey(entry.key, 'variables', sourcePath): _parseVariable(entry.value, entry.key, sourcePath),
    };
  }

  WorkflowVariable _parseVariable(Object? raw, Object? key, String? sourcePath) {
    final fieldPath = 'variables.${key.toString()}';
    if (raw == null) return const WorkflowVariable();
    if (raw is! YamlMap) {
      throw FormatException('Field "$fieldPath" must be a mapping${_at(sourcePath)}.');
    }
    _rejectUnknownFields(raw, _variableKeys, fieldPath, sourcePath);
    return WorkflowVariable(
      required: _optionalBool(raw['required'], '$fieldPath.required', sourcePath) ?? true,
      description: _optionalStringValue(raw['description'], '$fieldPath.description', sourcePath) ?? '',
      defaultValue: _optionalStringValue(raw['default'], '$fieldPath.default', sourcePath),
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
        steps.addAll(parsedForeach.nestedLoopSteps);
        inlineLoops.addAll(parsedForeach.nestedLoops);
      } else {
        steps.add(_parseStep(entry, sourcePath));
      }
    }
    return _ParsedSteps(steps: steps, inlineLoops: inlineLoops);
  }

  bool _isInlineLoopStep(YamlMap raw) => raw['type'] is String && (raw['type'] as String) == 'loop';

  bool _isInlineForeachStep(YamlMap raw) => raw['type'] is String && (raw['type'] as String) == 'foreach';

  _ParsedInlineForeachStep _parseInlineForeachStep(YamlMap raw, String? sourcePath) {
    final rawId = raw['id'];
    final blockLabel = rawId is String && rawId.isNotEmpty ? 'Foreach "$rawId"' : 'foreach step';
    _rejectUnknownFields(raw, _inlineForeachKeys, blockLabel, sourcePath);
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException('Foreach step must have a non-empty "id" field${_at(sourcePath)}.');
    }
    final name = raw['name'];
    if (name == null || name is! String || name.isEmpty) {
      throw FormatException('Foreach "$id" must have a non-empty "name" field${_at(sourcePath)}.');
    }
    final mapOver = _optionalStringValue(raw['map_over'] ?? raw['mapOver'], 'Foreach "$id": "map_over"', sourcePath);
    if (mapOver == null || mapOver.isEmpty) {
      throw FormatException('Foreach "$id" must specify "map_over"${_at(sourcePath)}.');
    }
    final childStepsRaw = raw['steps'];
    if (childStepsRaw is! YamlList || childStepsRaw.isEmpty) {
      throw FormatException('Foreach "$id" must include a non-empty "steps" list${_at(sourcePath)}.');
    }
    final childSteps = <WorkflowStep>[];
    final nestedLoops = <WorkflowLoop>[];
    final nestedLoopSteps = <WorkflowStep>[];
    for (final childRaw in childStepsRaw) {
      if (childRaw is! YamlMap) {
        throw FormatException('Foreach "$id" step entries must be mappings${_at(sourcePath)}.');
      }
      if (_isInlineForeachStep(childRaw)) {
        throw FormatException('Foreach "$id" cannot contain nested foreach steps${_at(sourcePath)}.');
      }
      if (_isInlineLoopStep(childRaw)) {
        // A loop nested in a foreach body converges independently per item.
        // Reuse the inline-loop parse for the body; synthesize a loop
        // controller step the foreach dispatches (loop-in-loop is still
        // rejected by _parseInlineLoopStep).
        final parsedLoop = _parseInlineLoopStep(childRaw, sourcePath);
        final loopName = childRaw['name'] as String;
        childSteps.add(WorkflowStep(id: parsedLoop.loop.id, name: loopName, taskType: WorkflowTaskType.loop));
        nestedLoops.add(parsedLoop.loop);
        nestedLoopSteps.addAll(parsedLoop.steps);
        if (parsedLoop.finalizerStep != null) {
          nestedLoopSteps.add(parsedLoop.finalizerStep!);
        }
        continue;
      }
      childSteps.add(_parseStep(childRaw, sourcePath));
    }
    final maxParallel = _parseMaxParallel(raw['max_parallel'] ?? raw['maxParallel'], id, sourcePath);
    final maxItems = _parseMaxItems(raw, id, sourcePath);
    final mapAlias = _parseMapAlias(raw['as'] ?? raw['mapAlias'] ?? raw['map_alias'], id, sourcePath);

    final outputs = _parseOutputs(raw['outputs'], id, sourcePath);
    final outputExamples = _parseOptionalStringList(raw['outputExamples'], 'Step "$id": "outputExamples"', sourcePath);
    final controller = WorkflowStep(
      id: id,
      name: name,
      taskType: WorkflowTaskType.foreach,
      mapOver: mapOver,
      maxParallel: maxParallel,
      maxItems: maxItems,
      gate: _optionalStringValue(raw['gate'], 'Foreach "$id": "gate"', sourcePath),
      entryGate: _optionalStringValue(raw['entryGate'], 'Foreach "$id": "entryGate"', sourcePath),
      inputs: _parseStringList(raw['inputs'], 'Step "$id": "inputs"', sourcePath),
      outputs: outputs,
      outputExamples: outputExamples,
      onFailure: _parseOnFailure(raw['onFailure'] ?? raw['on_failure'], id, sourcePath),
      foreachSteps: childSteps.map((s) => s.id).toList(growable: false),
      mapAlias: mapAlias,
      workflowVariables: _parseStringList(
        raw['workflow_variables'] ?? raw['workflowVariables'],
        'Step "$id": "workflow_variables"',
        sourcePath,
      ),
    );
    return _ParsedInlineForeachStep(
      controller: controller,
      childSteps: childSteps,
      nestedLoops: nestedLoops,
      nestedLoopSteps: nestedLoopSteps,
    );
  }

  _ParsedInlineLoopStep _parseInlineLoopStep(YamlMap raw, String? sourcePath) {
    final rawId = raw['id'];
    final blockLabel = rawId is String && rawId.isNotEmpty ? 'Inline loop "$rawId"' : 'inline loop step';
    _rejectUnknownFields(raw, _inlineLoopKeys, blockLabel, sourcePath);
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
        entryGate: _optionalStringValue(raw['entryGate'], 'Loop "$id": "entryGate"', sourcePath),
        exitGate: exitGate,
        finally_: finallyStepId,
        onMaxIterations:
            _optionalStringValue(raw['onMaxIterations'], 'Loop "$id": "onMaxIterations"', sourcePath) ??
            WorkflowLoop.onMaxIterationsFail,
      ),
      steps: loopSteps,
      finalizerStep: finalizerStep,
    );
  }

  WorkflowStep _parseStep(YamlMap raw, String? sourcePath) {
    final rawId = raw['id'];
    final blockLabel = rawId is String && rawId.isNotEmpty ? 'Step "$rawId"' : 'step';
    _rejectUnknownFields(raw, _stepKeys, blockLabel, sourcePath);
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException('Each step must have a non-empty "id" field${_at(sourcePath)}.');
    }
    final name = raw['name'];
    if (name == null || name is! String || name.isEmpty) {
      throw FormatException('Step "$id" must have a non-empty "name" field${_at(sourcePath)}.');
    }
    // Parse skill field (optional – skill-aware steps may omit prompt).
    final skill = _optionalStringValue(raw['skill'], 'Step "$id": "skill"', sourcePath);

    // Infer step type early so bash-specific YAML aliases can be parsed before
    // prompt validation runs.
    final rawStepType = _optionalStringValue(raw['type'], 'Step "$id": "type"', sourcePath) ?? 'agent';
    final stepType = _parseStepType(rawStepType, id, sourcePath);

    // Parse prompt – optional when skill is present.
    // Accepts: List<String> (canonical), String (legacy, normalized to
    // single-element list), or null (when skill is present).
    if (stepType == WorkflowTaskType.bash && raw.containsKey('prompt') && raw.containsKey('script')) {
      throw FormatException('Step "$id": use "script" or "prompt", not both${_at(sourcePath)}.');
    }
    if (stepType != WorkflowTaskType.bash && raw.containsKey('script')) {
      throw FormatException('Step "$id": "script" is only valid for type: bash steps${_at(sourcePath)}.');
    }
    final promptRaw = raw['prompt'] ?? (stepType == WorkflowTaskType.bash ? raw['script'] : null);
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

    // Reject no-skill + no-prompt at parse time, except for host-side steps
    // which do not need an agent prompt, and foreach controllers which are pure
    // orchestration containers (their child steps have the prompts).
    if (skill == null && (prompts == null || prompts.isEmpty)) {
      if (stepType != WorkflowTaskType.bash &&
          stepType != WorkflowTaskType.approval &&
          stepType != WorkflowTaskType.foreach &&
          stepType != WorkflowTaskType.aggregateReviews) {
        throw FormatException('Step "$id" must have either "prompt" or "skill" (or both)${_at(sourcePath)}.');
      }
    }

    final timeoutRaw = raw['timeout'] ?? raw['timeoutSeconds'] ?? raw['timeout_seconds'];
    int? timeoutSeconds;
    if (timeoutRaw != null) {
      if (timeoutRaw is String) {
        timeoutSeconds = parseDuration(timeoutRaw).inSeconds;
      } else if (timeoutRaw is int) {
        timeoutSeconds = timeoutRaw;
      }
    }

    final outputs = _parseOutputs(raw['outputs'], id, sourcePath);
    final outputExamples = _parseOptionalStringList(raw['outputExamples'], 'Step "$id": "outputExamples"', sourcePath);
    final aggregateReviews = _parseAggregateReviews(raw['aggregateReviews'], id, sourcePath);

    // Parse map step fields. Accept both snake_case (primary) and camelCase (alias).
    final mapOver = _optionalStringValue(raw['map_over'] ?? raw['mapOver'], 'Step "$id": "map_over"', sourcePath);
    final maxParallel = _parseMaxParallel(raw['max_parallel'] ?? raw['maxParallel'], id, sourcePath);
    final maxItems = _parseMaxItems(raw, id, sourcePath);
    final foreachStepsRaw = raw['foreach_steps'] ?? raw['foreachSteps'];
    final foreachSteps = foreachStepsRaw is YamlList
        ? _parseRequiredStringList(foreachStepsRaw, 'Step "$id": foreach_steps', sourcePath)
        : null;
    // `as:` is the primary spelling; `mapAlias:` / `map_alias:` also accepted for
    // round-trip compatibility with the JSON model.
    final mapAlias = _parseMapAlias(raw['as'] ?? raw['mapAlias'] ?? raw['map_alias'], id, sourcePath);

    return WorkflowStep(
      id: id,
      name: name,
      skill: skill,
      prompts: prompts,
      taskType: stepType,
      provider: _optionalStringValue(raw['provider'], 'Step "$id": "provider"', sourcePath),
      model: _optionalStringValue(raw['model'], 'Step "$id": "model"', sourcePath),
      effort: _optionalStringValue(raw['effort'], 'Step "$id": "effort"', sourcePath),
      gatingSeverity: _parseGatingSeverity(raw['gatingSeverity'], 'Step "$id": "gatingSeverity"', sourcePath),
      timeoutSeconds: timeoutSeconds,
      parallel: (_optionalBool(raw['parallel'], 'Step "$id": "parallel"', sourcePath)) ?? false,
      gate: _optionalStringValue(raw['gate'], 'Step "$id": "gate"', sourcePath),
      entryGate: _optionalStringValue(raw['entryGate'], 'Step "$id": "entryGate"', sourcePath),
      inputs: _parseStringList(raw['inputs'], 'Step "$id": "inputs"', sourcePath),
      outputs: outputs,
      outputExamples: outputExamples,
      maxTokens: _optionalInt(raw['maxTokens'], 'Step "$id": "maxTokens"', sourcePath),
      maxRetries: _optionalInt(raw['maxRetries'], 'Step "$id": "maxRetries"', sourcePath),
      allowedTools: _parseOptionalStringList(raw['allowedTools'], 'Step "$id": "allowedTools"', sourcePath),
      aggregateReviews: aggregateReviews,
      mapOver: mapOver,
      maxParallel: maxParallel,
      maxItems: maxItems,
      foreachSteps: foreachSteps,
      mapAlias: mapAlias,
      continueSession: _parseContinueSession(raw['continueSession'] ?? raw['continue_session'], id, sourcePath),
      onError: _parseOnError(raw['onError'] ?? raw['on_error'], id, sourcePath),
      workdir: _optionalStringValue(raw['workdir'], 'Step "$id": "workdir"', sourcePath),
      onFailure: _parseOnFailure(raw['onFailure'] ?? raw['on_failure'], id, sourcePath),
      emitsOwnOutcome: _parseEmitsOwnOutcome(raw['emitsOwnOutcome'] ?? raw['emits_own_outcome'], id, sourcePath),
      autoFrameContext: _parseAutoFrameContext(raw['auto_frame_context'] ?? raw['autoFrameContext'], id, sourcePath),
      workflowVariables: _parseStringList(
        raw['workflow_variables'] ?? raw['workflowVariables'],
        'Step "$id": "workflow_variables"',
        sourcePath,
      ),
    );
  }

  WorkflowTaskType _parseStepType(String value, String stepId, String? sourcePath) {
    if (value == 'custom') {
      throw FormatException(
        'Step "$stepId" uses removed step type "custom". '
        'Supported types: ${WorkflowTaskType.values.map((type) => type.toJson()).join(', ')}. '
        'Omit "type:" entirely for agent steps (the default). '
        'The agent-step marker has been renamed to "agent"${_at(sourcePath)}.',
      );
    }
    try {
      return WorkflowTaskType.fromJsonString(value);
    } on FormatException catch (e) {
      throw FormatException('${e.message}${_at(sourcePath)}.');
    }
  }

  List<String>? _parseAggregateReviews(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! YamlList) {
      throw FormatException(
        'Step "$stepId": aggregateReviews must be a list of upstream step ids; offending value: '
        '${_yamlToValue(raw)}${_at(sourcePath)}.',
      );
    }
    if (raw.isEmpty) {
      throw FormatException(
        'Step "$stepId": aggregateReviews must list at least one upstream step id; offending value: []'
        '${_at(sourcePath)}.',
      );
    }
    final values = <String>[];
    for (final item in raw) {
      if (item is! String || item.isEmpty) {
        throw FormatException(
          'Step "$stepId": aggregateReviews entries must be non-empty strings; offending value: '
          '${_yamlToValue(item)}${_at(sourcePath)}.',
        );
      }
      values.add(item);
    }
    return values;
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

  OnErrorPolicy? _parseOnError(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! String) {
      throw FormatException('Step "$stepId": "onError" must be a string${_at(sourcePath)}.');
    }
    final policy = OnErrorPolicy.fromYaml(raw);
    if (policy == null) {
      throw FormatException(
        'Step "$stepId": unknown onError value "$raw" (expected pause, continue)${_at(sourcePath)}.',
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
        'Step "$stepId": "as: $trimmed" is reserved – pick a different identifier${_at(sourcePath)}.',
      );
    }
    return trimmed;
  }

  /// Rejects the retired review output key `review_findings` (bare or
  /// `<stepId>.review_findings`), which was renamed to `review_report_path` so
  /// the key matches its own schema preset. Early-experimental stance: a loud
  /// pointered rejection beats a permanent back-compat alias.
  void _rejectRetiredReviewFindingsKey(String key, String stepId, String? sourcePath) {
    if (key == 'review_findings' || key.endsWith('.review_findings')) {
      final replacement = key.replaceFirst(RegExp(r'review_findings$'), 'review_report_path');
      throw FormatException(
        'Step "$stepId": output key "$key" uses the retired name "review_findings"; '
        'rename it to $replacement (the review-report path key matches its preset)${_at(sourcePath)}.',
      );
    }
  }

  Map<String, OutputConfig>? _parseOutputs(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! YamlMap) {
      throw FormatException('Step "$stepId": "outputs" must be a mapping${_at(sourcePath)}.');
    }
    final outputs = <String, OutputConfig>{};
    for (final entry in raw.entries) {
      final key = _requireYamlStringKey(entry.key, 'Step "$stepId": "outputs"', sourcePath);
      _rejectRetiredReviewFindingsKey(key, stepId, sourcePath);
      final value = entry.value;
      if (value is YamlMap) {
        _rejectUnknownFields(value, _outputConfigKeys, 'Step "$stepId" output "$key"', sourcePath);
        final schema = _parseSchema(value['schema']);
        final formatRaw = _optionalStringValue(value['format'], 'Step "$stepId" output "$key": "format"', sourcePath);
        final format = formatRaw != null
            ? (OutputFormat.fromYaml(formatRaw) ??
                  (throw FormatException(
                    'Step "$stepId" output "$key": unknown format "$formatRaw"${_at(sourcePath)}.',
                  )))
            : (schema is String ? schemaPresets[schema]?.format : null) ?? OutputFormat.text;
        final outputSource = _optionalStringValue(
          value['source'],
          'Step "$stepId" output "$key": "source"',
          sourcePath,
        );
        final resolverOverride = _parseOutputResolver(value, format, stepId, key, sourcePath);
        final outputModeRaw = _optionalStringValue(
          value['outputMode'] ?? value['output_mode'],
          'Step "$stepId" output "$key": "outputMode"',
          sourcePath,
        );
        final outputMode = outputModeRaw != null
            ? (OutputMode.fromYaml(outputModeRaw) ??
                  (throw FormatException(
                    'Step "$stepId" output "$key": unknown outputMode "$outputModeRaw"${_at(sourcePath)}.',
                  )))
            : (format == OutputFormat.json && schema != null ? OutputMode.structured : OutputMode.prompt);
        final description = _optionalStringValue(
          value['description'],
          'Step "$stepId" output "$key": "description"',
          sourcePath,
        );
        // `setValue` accepts any JSON-encodable literal (null, string, number,
        // bool, list, map). Presence of the key – even with a null value –
        // means "explicitly set"; absence means "extract normally".
        final hasSetValue = value.containsKey('setValue') || value.containsKey('set_value');
        outputs[key] = hasSetValue
            ? OutputConfig(
                format: format,
                schema: schema,
                source: outputSource,
                resolverOverride: resolverOverride,
                outputMode: outputMode,
                description: description,
                setValue: _yamlToValue(value['setValue'] ?? value['set_value']),
              )
            : OutputConfig(
                format: format,
                schema: schema,
                source: outputSource,
                resolverOverride: resolverOverride,
                outputMode: outputMode,
                description: description,
              );
      } else {
        // Shorthand: `key: json`, `key: lines`, or `key: preset_name`.
        final shorthand = value.toString();
        final format = OutputFormat.fromYaml(shorthand);
        if (format != null) {
          outputs[key] = OutputConfig(format: format);
          continue;
        }
        final preset = schemaPresets[shorthand];
        if (preset != null) {
          final outputMode = preset.format == OutputFormat.json ? OutputMode.structured : OutputMode.prompt;
          outputs[key] = OutputConfig(format: preset.format, schema: shorthand, outputMode: outputMode);
          continue;
        }
        final formats = OutputFormat.values.map((value) => value.name).join(', ');
        throw FormatException(
          'Step "$stepId" output "$key": unknown output shorthand "$shorthand"; expected one of '
          'format keywords [$formats] or a registered schema preset${_at(sourcePath)}.',
        );
      }
    }
    return outputs;
  }

  OutputResolver? _parseOutputResolver(
    YamlMap value,
    OutputFormat format,
    String stepId,
    String key,
    String? sourcePath,
  ) {
    final resolverValue = value['resolver'];
    final hasPathPattern = value.containsKey('pathPattern') || value.containsKey('path_pattern');
    final hasListMode = value.containsKey('listMode') || value.containsKey('list_mode');
    final hasPreferPatterns = value.containsKey('preferPatterns') || value.containsKey('prefer_patterns');
    if (resolverValue == null) {
      if (hasPathPattern || hasListMode || hasPreferPatterns) {
        if (format == OutputFormat.path) {
          return _parseFileSystemOutput(value, stepId, key, sourcePath);
        }
        throw FormatException(
          'Step "$stepId" output "$key": pathPattern/listMode/preferPatterns require format: path or resolver: filesystem'
          '${_at(sourcePath)}.',
        );
      }
      return null;
    }

    if (resolverValue is YamlMap || resolverValue is Map<Object?, Object?>) {
      if (hasPathPattern || hasListMode || hasPreferPatterns) {
        throw FormatException(
          'Step "$stepId" output "$key": pathPattern/listMode/preferPatterns must be declared inside the resolver map when resolver is an object${_at(sourcePath)}.',
        );
      }
      if (resolverValue is YamlMap) {
        _rejectUnknownFields(resolverValue, _outputResolverKeys, 'Step "$stepId" output "$key" resolver', sourcePath);
      }
      final resolverJson = Map<String, Object?>.from(
        (resolverValue as Map).map((key, value) => MapEntry(key.toString(), _yamlToValue(value))),
      );
      return OutputResolver.fromJson(resolverJson);
    }

    final resolverRaw = _optionalStringValue(resolverValue, 'Step "$stepId" output "$key": "resolver"', sourcePath);
    final resolver = resolverRaw!.trim().toLowerCase();
    if ((resolver == 'inline' || resolver == 'narrative') && (hasPathPattern || hasListMode || hasPreferPatterns)) {
      throw FormatException(
        'Step "$stepId" output "$key": pathPattern/listMode/preferPatterns are only valid with resolver: filesystem${_at(sourcePath)}.',
      );
    }

    return switch (resolver) {
      'inline' => InlineOutput(schemaKey: key),
      'narrative' => InlineOutput(schemaKey: key),
      'filesystem' => _parseFileSystemOutput(value, stepId, key, sourcePath),
      _ => throw FormatException(
        'Step "$stepId" output "$key": resolver must be one of inline, narrative, filesystem${_at(sourcePath)}.',
      ),
    };
  }

  FileSystemOutput _parseFileSystemOutput(YamlMap value, String stepId, String key, String? sourcePath) =>
      FileSystemOutput(
        pathPattern:
            _optionalStringValue(
              value['pathPattern'] ?? value['path_pattern'],
              'Step "$stepId" output "$key": "pathPattern"',
              sourcePath,
            ) ??
            '**/*',
        listMode:
            _optionalBool(
              value['listMode'] ?? value['list_mode'],
              'Step "$stepId" output "$key": "listMode"',
              sourcePath,
            ) ??
            false,
        preferPatterns: _parseStringList(
          value['preferPatterns'] ?? value['prefer_patterns'],
          'Step "$stepId" output "$key": "preferPatterns"',
          sourcePath,
        ),
      );

  /// Parses the `max_parallel` value from YAML.
  ///
  /// Accepts int (concurrency limit), String "unlimited", or String template.
  /// Returns null if absent.
  Object? _parseMaxParallel(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return null;
    if (raw is int) {
      if (raw <= 0) {
        throw FormatException(
          'Step "$stepId": "max_parallel" must be a positive integer, '
          '"unlimited", or a template string${_at(sourcePath)}.',
        );
      }
      return raw;
    }
    if (raw is String) return raw;
    throw FormatException(
      'Step "$stepId": "max_parallel" must be an integer or string '
      '(e.g., 3, "unlimited", or a template like "{{MAX_PARALLEL}}")${_at(sourcePath)}.',
    );
  }

  int? _parseMaxItems(YamlMap raw, String stepId, String? sourcePath) {
    final key = raw.containsKey('max_items')
        ? 'max_items'
        : raw.containsKey('maxItems')
        ? 'maxItems'
        : null;
    if (key == null) return null;

    final value = raw[key];
    if (value is int && value > 0) return value;
    throw FormatException('Step "$stepId": "$key" must be a positive integer${_at(sourcePath)}.');
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

  WorkflowGitStrategy? _parseGitStrategy(Object? raw, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! YamlMap) {
      throw FormatException('Field "gitStrategy" must be a mapping${_at(sourcePath)}.');
    }
    _rejectUnknownFields(raw, _gitStrategyKeys, 'gitStrategy', sourcePath);
    final publishRaw = raw['publish'];
    bool? publish;
    if (publishRaw != null) {
      if (publishRaw is! YamlMap) {
        throw FormatException('Field "gitStrategy.publish" must be a mapping${_at(sourcePath)}.');
      }
      _rejectUnknownFields(publishRaw, _gitPublishKeys, 'gitStrategy.publish', sourcePath);
      publish = _optionalBool(publishRaw['enabled'], 'gitStrategy.publish.enabled', sourcePath);
    }

    final cleanupRaw = raw['cleanup'];
    bool? cleanup;
    if (cleanupRaw != null) {
      if (cleanupRaw is! YamlMap) {
        throw FormatException('Field "gitStrategy.cleanup" must be a mapping${_at(sourcePath)}.');
      }
      _rejectUnknownFields(cleanupRaw, _gitCleanupKeys, 'gitStrategy.cleanup', sourcePath);
      final enabledRaw = cleanupRaw['enabled'];
      if (enabledRaw != null && enabledRaw is! bool) {
        throw FormatException('Field "gitStrategy.cleanup.enabled" must be a boolean${_at(sourcePath)}.');
      }
      cleanup = enabledRaw as bool?;
    }

    final artifactsRaw = raw['artifacts'];
    WorkflowGitArtifactsStrategy? artifacts;
    if (artifactsRaw != null) {
      if (artifactsRaw is! YamlMap) {
        throw FormatException('Field "gitStrategy.artifacts" must be a mapping${_at(sourcePath)}.');
      }
      _rejectUnknownFields(artifactsRaw, _gitArtifactsKeys, 'gitStrategy.artifacts', sourcePath);
      artifacts = WorkflowGitArtifactsStrategy(
        commit: _optionalBool(artifactsRaw['commit'], 'gitStrategy.artifacts.commit', sourcePath),
        commitMessage: _optionalStringValue(
          artifactsRaw['commitMessage'] ?? artifactsRaw['commit_message'],
          'gitStrategy.artifacts.commitMessage',
          sourcePath,
        ),
        project: _optionalStringValue(artifactsRaw['project'], 'gitStrategy.artifacts.project', sourcePath),
      );
    }

    final worktreeRaw = raw['worktree'];
    WorkflowGitWorktreeStrategy? worktree;
    WorkflowGitExternalArtifactMount? nestedMount;
    if (worktreeRaw != null) {
      if (worktreeRaw is String) {
        worktree = WorkflowGitWorktreeStrategy(
          mode: _parseWorktreeMode(worktreeRaw, 'gitStrategy.worktree', sourcePath),
        );
      } else if (worktreeRaw is YamlMap) {
        _rejectUnknownFields(worktreeRaw, _gitWorktreeKeys, 'gitStrategy.worktree', sourcePath);
        nestedMount = _parseExternalArtifactMount(
          worktreeRaw['externalArtifactMount'] ?? worktreeRaw['external_artifact_mount'],
          sourcePath,
          'gitStrategy.worktree.externalArtifactMount',
        );
        worktree = WorkflowGitWorktreeStrategy(
          mode: switch (_optionalStringValue(worktreeRaw['mode'], 'gitStrategy.worktree.mode', sourcePath)) {
            final mode? => _parseWorktreeMode(mode, 'gitStrategy.worktree.mode', sourcePath),
            null => null,
          },
          externalArtifactMount: nestedMount,
        );
      } else {
        throw FormatException('Field "gitStrategy.worktree" must be a string or mapping${_at(sourcePath)}.');
      }
    }
    worktree ??= WorkflowGitWorktreeStrategy();

    final integrationBranchRaw = _resolveIntegrationBranchYamlValue(raw, sourcePath);

    final rawMergeResolve = raw['merge_resolve'] ?? raw['mergeResolve'];
    return WorkflowGitStrategy(
      integrationBranch: integrationBranchRaw,
      worktree: worktree,
      promotion: _optionalStringValue(raw['promotion'], 'gitStrategy.promotion', sourcePath),
      publish: publish,
      cleanup: cleanup,
      artifacts: artifacts,
      mergeResolve: rawMergeResolve != null ? MergeResolveConfig.fromJson(rawMergeResolve) : null,
    );
  }

  bool? _resolveIntegrationBranchYamlValue(YamlMap raw, String? sourcePath) {
    return resolveWorkflowIntegrationBranchValue(
      (key) => raw[key],
      typeError: (fieldPath) => FormatException('Field "$fieldPath" must be a boolean${_at(sourcePath)}.'),
      disagreementError: (fieldPaths) =>
          FormatException('Fields ${quotedWorkflowFieldList(fieldPaths)} must not disagree${_at(sourcePath)}.'),
    );
  }

  WorkflowGitExternalArtifactMount? _parseExternalArtifactMount(Object? raw, String? sourcePath, String fieldPath) {
    if (raw == null) return null;
    if (raw is! YamlMap) {
      throw FormatException('Field "$fieldPath" must be a mapping${_at(sourcePath)}.');
    }
    _rejectUnknownFields(raw, _externalArtifactMountKeys, fieldPath, sourcePath);
    final fromProject = raw['fromProject'] ?? raw['from_project'];
    if (fromProject is! String || fromProject.trim().isEmpty) {
      throw FormatException('Field "$fieldPath.fromProject" is required${_at(sourcePath)}.');
    }
    final mode = _parseExternalArtifactMountMode(
      _optionalStringValue(raw['mode'], '$fieldPath.mode', sourcePath) ?? 'per-story-copy',
      '$fieldPath.mode',
      sourcePath,
    );
    return WorkflowGitExternalArtifactMount(
      mode: mode,
      fromProject: fromProject,
      source: _optionalStringValue(raw['source'], '$fieldPath.source', sourcePath),
      fromPath: _optionalStringValue(raw['fromPath'] ?? raw['from_path'], '$fieldPath.fromPath', sourcePath),
      toPath: _optionalStringValue(raw['toPath'] ?? raw['to_path'], '$fieldPath.toPath', sourcePath),
      readonly: _optionalBool(raw['readonly'], '$fieldPath.readonly', sourcePath),
    );
  }

  WorkflowGitWorktreeMode _parseWorktreeMode(String value, String fieldPath, String? sourcePath) {
    try {
      return WorkflowGitWorktreeMode.fromJsonString(value);
    } on FormatException catch (e) {
      throw FormatException('Field "$fieldPath": ${e.message}${_at(sourcePath)}.');
    }
  }

  WorkflowExternalArtifactMountMode _parseExternalArtifactMountMode(
    String value,
    String fieldPath,
    String? sourcePath,
  ) {
    try {
      return WorkflowExternalArtifactMountMode.fromJsonString(value);
    } on FormatException catch (e) {
      throw FormatException('Field "$fieldPath": ${e.message}${_at(sourcePath)}.');
    }
  }

  List<StepConfigDefault>? _parseStepDefaults(Object? raw, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! YamlList) {
      throw FormatException('Field "stepDefaults" must be a list${_at(sourcePath)}.');
    }
    return raw
        .map((entry) {
          if (entry is! YamlMap) {
            throw FormatException('Each stepDefaults entry must be a mapping${_at(sourcePath)}.');
          }
          final match = entry['match'];
          final blockLabel = match is String && match.isNotEmpty ? 'stepDefaults "$match"' : 'stepDefaults entry';
          _rejectUnknownFields(entry, _stepDefaultKeys, blockLabel, sourcePath);
          if (match == null || match is! String || match.isEmpty) {
            throw FormatException('Each stepDefaults entry must have a non-empty "match" field${_at(sourcePath)}.');
          }
          return StepConfigDefault(
            match: match,
            provider: _optionalStringValue(entry['provider'], 'stepDefaults.provider', sourcePath),
            model: _optionalStringValue(entry['model'], 'stepDefaults.model', sourcePath),
            effort: _optionalStringValue(entry['effort'], 'stepDefaults.effort', sourcePath),
            gatingSeverity: _parseGatingSeverity(entry['gatingSeverity'], 'stepDefaults.gatingSeverity', sourcePath),
            maxTokens: _optionalInt(entry['maxTokens'], 'stepDefaults.maxTokens', sourcePath),
            maxRetries: _optionalInt(entry['maxRetries'], 'stepDefaults.maxRetries', sourcePath),
            timeoutSeconds: _optionalInt(
              entry['timeout_seconds'] ?? entry['timeoutSeconds'],
              'stepDefaults.timeout_seconds',
              sourcePath,
            ),
            allowedTools: _parseOptionalStringList(entry['allowedTools'], 'stepDefaults.allowedTools', sourcePath),
          );
        })
        .toList(growable: false);
  }

  String? _parseGatingSeverity(Object? raw, String fieldPath, String? sourcePath) {
    final value = _optionalStringValue(raw, fieldPath, sourcePath);
    if (value == null) return null;
    final normalized = value.trim().toLowerCase();
    if (!isValidReviewFindingSeverity(normalized)) {
      throw FormatException('$fieldPath must be one of ${reviewFindingSeverityTiers.join(', ')}${_at(sourcePath)}.');
    }
    return normalized;
  }

  List<String> _parseStringList(Object? raw, String fieldPath, String? sourcePath) {
    if (raw == null) return const [];
    if (raw is! YamlList) {
      throw FormatException('$fieldPath must be a list of strings${_at(sourcePath)}.');
    }
    return _parseRequiredStringList(raw, fieldPath, sourcePath);
  }

  List<String>? _parseOptionalStringList(Object? raw, String fieldPath, String? sourcePath) {
    if (raw == null) return null;
    if (raw is! YamlList) {
      throw FormatException('$fieldPath must be a list of strings${_at(sourcePath)}.');
    }
    return _parseRequiredStringList(raw, fieldPath, sourcePath);
  }

  List<String> _parseRequiredStringList(YamlList raw, String fieldPath, String? sourcePath) {
    final values = <String>[];
    for (final item in raw) {
      if (item is! String) {
        throw FormatException('$fieldPath entries must be strings${_at(sourcePath)}.');
      }
      values.add(item);
    }
    return values;
  }

  String _requireYamlStringKey(Object? raw, String fieldPath, String? sourcePath) {
    if (raw is String && raw.isNotEmpty) return raw;
    throw FormatException('$fieldPath keys must be non-empty strings${_at(sourcePath)}.');
  }

  String? _optionalStringValue(Object? raw, String fieldPath, String? sourcePath) {
    if (raw == null) return null;
    if (raw is String) return raw;
    throw FormatException('$fieldPath must be a string${_at(sourcePath)}.');
  }

  bool? _optionalBool(Object? raw, String fieldPath, String? sourcePath) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    throw FormatException('$fieldPath must be a boolean${_at(sourcePath)}.');
  }

  int? _optionalInt(Object? raw, String fieldPath, String? sourcePath) {
    if (raw == null) return null;
    if (raw is int) return raw;
    throw FormatException('$fieldPath must be an integer${_at(sourcePath)}.');
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

  /// Child steps the foreach dispatches per item, in order. A `type: loop`
  /// child contributes its loop *controller* step here (not its body steps).
  final List<WorkflowStep> childSteps;

  /// Inline loops declared directly inside the foreach body. Their controller
  /// step ids appear in [childSteps]; their body steps are in [nestedLoopSteps].
  final List<WorkflowLoop> nestedLoops;

  /// Body (and finalizer) steps of the foreach-nested loops. Flattened into the
  /// definition's `steps` list but owned by the loop, not the foreach node.
  final List<WorkflowStep> nestedLoopSteps;

  const _ParsedInlineForeachStep({
    required this.controller,
    required this.childSteps,
    this.nestedLoops = const [],
    this.nestedLoopSteps = const [],
  });
}
