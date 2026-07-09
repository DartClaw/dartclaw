import 'workflow_definition.dart';

import 'step_config_resolver.dart' show globMatchStepId;

/// Resolves a [WorkflowDefinition] into the fully-merged form the engine
/// executes: per-step fields concretized from pattern-based `stepDefaults`,
/// and workflow-level
/// `{{VAR}}` bindings substituted in step prompts when a binding is
/// available. Runtime-only references (`{{context.key}}` and unbound
/// `{{VAR}}`) are preserved verbatim so the resolved YAML is still a
/// valid workflow definition.
///
/// The resolver is deterministic and pure — no side effects, no IO.
/// Outputs round-trip through [WorkflowDefinitionParser] (by design — it
/// is the observability surface for the `workflow show --resolved` CLI).
class WorkflowDefinitionResolver {
  const WorkflowDefinitionResolver();

  /// Returns a new [WorkflowDefinition] with `stepDefaults` applied and `{{VAR}}` references in prompts substituted
  /// when [variableBindings] contains the key.
  ///
  /// The emitted definition no longer carries `stepDefaults` (already
  /// applied) and recomputes `nodes` via [WorkflowDefinition.normalizeNodes].
  WorkflowDefinition resolve(WorkflowDefinition def, {Map<String, String>? variableBindings}) {
    final resolvedSteps = def.steps
        .map((step) => _resolveStep(step, def.stepDefaults, variableBindings))
        .toList(growable: false);
    final resolvedProject = switch ((def.project, variableBindings)) {
      (final String project, final Map<String, String> bindings) when bindings.isNotEmpty => _substituteVariables(
        project,
        bindings,
      ),
      (final String project, _) => project,
      _ => null,
    };
    return WorkflowDefinition(
      name: def.name,
      description: def.description,
      variables: def.variables,
      steps: resolvedSteps,
      loops: def.loops,
      nodes: WorkflowDefinition.normalizeNodes(resolvedSteps, def.loops),
      maxTokens: def.maxTokens,
      project: resolvedProject,
      // stepDefaults intentionally dropped — already baked into each step.
      gitStrategy: def.gitStrategy,
    );
  }

  /// Extracts a single step (authored order) from a resolved definition as
  /// its own [WorkflowDefinition]. The returned definition carries just the
  /// requested step plus any loops it participates in, so the emitter can
  /// produce a compact single-step YAML document without dangling references.
  WorkflowDefinition? sliceStep(WorkflowDefinition resolved, String stepId) {
    final stepsById = {for (final step in resolved.steps) step.id: step};
    final loopsById = {for (final loop in resolved.loops) loop.id: loop};
    final step = stepsById[stepId];
    if (step == null) return null;
    final selectedStepIds = <String>{};
    final selectedLoopIds = <String>{};
    void includeStepTree(String id) {
      if (!selectedStepIds.add(id)) return;
      final step = stepsById[id];
      if (step == null) return;
      if (step.isForeachController) {
        for (final childId in step.foreachSteps!) {
          includeStepTree(childId);
        }
      }
      final loop = loopsById[id];
      if (loop != null) {
        selectedLoopIds.add(loop.id);
        for (final bodyStepId in loop.steps) {
          includeStepTree(bodyStepId);
        }
        final finalizer = loop.finally_;
        if (finalizer != null) includeStepTree(finalizer);
      }
    }

    includeStepTree(stepId);
    final selectedSteps = [
      for (final step in resolved.steps)
        if (selectedStepIds.contains(step.id)) step,
    ];
    final selectedLoops = [
      for (final loop in resolved.loops)
        if (selectedLoopIds.contains(loop.id)) loop,
    ];
    // Preserve the workflow-level variable declarations so any `{{VAR}}`
    // references the step's prompt still carries resolve cleanly when the
    // sliced YAML is fed back through the parser or used as a runnable
    // single-step definition.
    return WorkflowDefinition(
      name: resolved.name,
      description: resolved.description,
      variables: resolved.variables,
      project: resolved.project,
      steps: selectedSteps,
      loops: selectedLoops,
      nodes: WorkflowDefinition.normalizeNodes(selectedSteps, selectedLoops),
    );
  }

  WorkflowStep _resolveStep(
    WorkflowStep step,
    List<StepConfigDefault>? stepDefaults,
    Map<String, String>? variableBindings,
  ) {
    // 1. Pattern-based stepDefaults — first match wins; explicit step field wins.
    StepConfigDefault? matched;
    if (stepDefaults != null) {
      for (final d in stepDefaults) {
        if (globMatchStepId(d.match, step.id)) {
          matched = d;
          break;
        }
      }
    }

    final resolvedProvider = step.provider ?? matched?.provider;

    List<String>? resolvedPrompts = step.prompts;
    if (resolvedPrompts != null && variableBindings != null && variableBindings.isNotEmpty) {
      resolvedPrompts = resolvedPrompts
          .map((prompt) => _substituteVariables(prompt, variableBindings))
          .toList(growable: false);
    }

    return step.copyWith(
      prompts: resolvedPrompts,
      provider: resolvedProvider,
      model: step.model ?? matched?.model,
      effort: step.effort ?? matched?.effort,
      gatingSeverity: step.gatingSeverity ?? matched?.gatingSeverity,
      outputs: step.outputs,
      maxTokens: step.maxTokens ?? matched?.maxTokens,
      maxRetries: step.maxRetries ?? matched?.maxRetries,
      timeoutSeconds: step.timeoutSeconds ?? matched?.timeoutSeconds,
      allowedTools: step.allowedTools ?? matched?.allowedTools,
      emitsOwnOutcome: step.emitsOwnOutcome,
    );
  }

  /// Replaces `{{KEY}}` occurrences in [input] with the corresponding value
  /// from [bindings]. Unknown keys and `{{context.*}}` references stay as
  /// literal template strings — those resolve at runtime against the
  /// step-execution context, which the resolver has no visibility into.
  String _substituteVariables(String input, Map<String, String> bindings) {
    if (!input.contains('{{')) return input;
    return input.replaceAllMapped(RegExp(r'\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}'), (match) {
      final key = match.group(1)!;
      final value = bindings[key];
      // Leave unknown or `context.*`-prefixed references intact; the parser
      // still accepts the emitted YAML even when some `{{VAR}}` remain.
      return value ?? match.group(0)!;
    });
  }

  /// Emits [def] as YAML. The output round-trips through
  /// [WorkflowDefinitionParser].
  ///
  /// Intentionally minimal: block-style maps, flow-style scalars, `|` block
  /// scalars for multi-line strings. No anchors, no tags, no merges — those
  /// aren't part of the DartClaw workflow schema.
  String emitYaml(WorkflowDefinition def) {
    final buf = StringBuffer();
    final jsonLike = _workflowToOrderedMap(def);
    _writeNode(buf, jsonLike, indent: 0, inList: false);
    return buf.toString();
  }

  // ── YAML emitter ──────────────────────────────────────────────────────

  /// Serializes [def] into an ordered list of `(key, value)` entries so the
  /// emitted YAML preserves a stable, human-friendly field order (name,
  /// description, variables, stepDefaults, gitStrategy, steps).
  List<MapEntry<String, dynamic>> _workflowToOrderedMap(WorkflowDefinition def) {
    final entries = <MapEntry<String, dynamic>>[MapEntry('name', def.name), MapEntry('description', def.description)];
    if (def.variables.isNotEmpty) {
      // Emit the YAML authoring key `default` — toJson()'s `defaultValue` is the
      // persisted-JSON shape, not a parser-known authoring field.
      entries.add(
        MapEntry(
          'variables',
          def.variables.map(
            (k, v) => MapEntry(k, <String, dynamic>{
              'required': v.required,
              'description': v.description,
              if (v.defaultValue != null) 'default': v.defaultValue,
            }),
          ),
        ),
      );
    }
    if (def.maxTokens != null) entries.add(MapEntry('maxTokens', def.maxTokens));
    if (def.project != null) entries.add(MapEntry('project', def.project));
    if (def.gitStrategy != null) entries.add(MapEntry('gitStrategy', def.gitStrategy!.toJson()));
    if (def.stepDefaults != null && def.stepDefaults!.isNotEmpty) {
      entries.add(MapEntry('stepDefaults', def.stepDefaults!.map((d) => d.toJson()).toList()));
    }
    entries.add(MapEntry('steps', _buildTopLevelStepList(def)));
    return entries;
  }

  /// IDs of loops whose controller step is owned by a `foreach` (its id is in
  /// some foreach controller's `foreachSteps`). These round-trip inline.
  Set<String> _foreachOwnedLoopIds(WorkflowDefinition def) {
    final foreachOwnedStepIds = {
      for (final step in def.steps)
        if (step.isForeachController) ...step.foreachSteps!,
    };
    return {
      for (final loop in def.loops)
        if (foreachOwnedStepIds.contains(loop.id)) loop.id,
    };
  }

  /// Assembles the `steps:` list, inlining foreach child steps under their
  /// controller (matches the inline-foreach form the parser expects) and
  /// omitting the separately-listed child entries at the top level.
  List<dynamic> _buildTopLevelStepList(WorkflowDefinition def) {
    final stepsById = {for (final s in def.steps) s.id: s};
    final loopsById = {for (final l in def.loops) l.id: l};
    final foreachOwnedLoopIds = _foreachOwnedLoopIds(def);
    final topLevelLoopByControllerId = {
      for (final loop in def.loops)
        if (!foreachOwnedLoopIds.contains(loop.id) && stepsById.containsKey(loop.id)) loop.id: loop,
    };
    final topLevelLoopByFirstBodyStepId = {
      for (final loop in def.loops)
        if (!foreachOwnedLoopIds.contains(loop.id) && !stepsById.containsKey(loop.id) && loop.steps.isNotEmpty)
          loop.steps.first: loop,
    };
    final inlinedChildIds = <String>{};
    for (final step in def.steps) {
      if (step.isForeachController) inlinedChildIds.addAll(step.foreachSteps!);
    }
    // Loop body and finalizer steps are emitted inside their inline loop
    // controller, so suppress them at the top level too.
    for (final loop in def.loops) {
      inlinedChildIds.addAll(loop.steps);
      if (loop.finally_ != null) inlinedChildIds.add(loop.finally_!);
    }
    final result = <dynamic>[];
    final emittedLoopIds = <String>{};
    for (final step in def.steps) {
      final loopAtBodyStart = topLevelLoopByFirstBodyStepId[step.id];
      if (loopAtBodyStart != null && emittedLoopIds.add(loopAtBodyStart.id)) {
        result.add(_inlineLoopToOrderedMap(null, loopAtBodyStart, stepsById));
        continue;
      }
      if (inlinedChildIds.contains(step.id)) continue; // emitted under its controller
      if (step.isForeachController) {
        result.add(_foreachControllerToOrderedMap(step, stepsById, loopsById));
      } else if (topLevelLoopByControllerId.containsKey(step.id) && emittedLoopIds.add(step.id)) {
        result.add(_inlineLoopToOrderedMap(step, topLevelLoopByControllerId[step.id]!, stepsById));
      } else {
        result.add(_stepToOrderedMap(step));
      }
    }
    return result;
  }

  /// Emits a foreach controller in the inline form the parser expects —
  /// with a nested `steps:` list containing the resolved child steps.
  List<MapEntry<String, dynamic>> _foreachControllerToOrderedMap(
    WorkflowStep controller,
    Map<String, WorkflowStep> stepsById,
    Map<String, WorkflowLoop> loopsById,
  ) {
    final entries = <MapEntry<String, dynamic>>[
      MapEntry('id', controller.id),
      MapEntry('name', controller.name),
      MapEntry('type', 'foreach'),
    ];
    if (controller.mapOver != null) entries.add(MapEntry('map_over', controller.mapOver));
    if (controller.mapAlias != null) entries.add(MapEntry('as', controller.mapAlias));
    if (controller.maxParallel != null) entries.add(MapEntry('max_parallel', controller.maxParallel));
    if (controller.maxItems != null) entries.add(MapEntry('max_items', controller.maxItems));
    if (controller.gate != null) entries.add(MapEntry('gate', controller.gate));
    if (controller.entryGate != null) entries.add(MapEntry('entryGate', controller.entryGate));
    if (controller.inputs.isNotEmpty) {
      entries.add(MapEntry('inputs', controller.inputs.toList()));
    }
    if (controller.outputs != null && controller.outputs!.isNotEmpty) {
      entries.add(MapEntry('outputs', controller.outputs!.map((k, v) => MapEntry(k, v.toJson()))));
    }
    if (controller.outputExamples != null) {
      entries.add(MapEntry('outputExamples', controller.outputExamples!.toList(growable: false)));
    }
    if (controller.onFailure != OnFailurePolicy.fail) entries.add(MapEntry('onFailure', controller.onFailure.yamlName));
    if (controller.workflowVariables.isNotEmpty) {
      entries.add(MapEntry('workflow_variables', controller.workflowVariables.toList()));
    }
    final childSteps = <dynamic>[];
    for (final childId in controller.foreachSteps ?? const <String>[]) {
      final loop = loopsById[childId];
      if (loop != null) {
        // A foreach-nested loop child round-trips in full inline form so the
        // parser can re-materialize maxIterations/gates/body.
        childSteps.add(_inlineLoopToOrderedMap(stepsById[childId], loop, stepsById));
        continue;
      }
      final child = stepsById[childId];
      if (child != null) childSteps.add(_stepToOrderedMap(child));
    }
    entries.add(MapEntry('steps', childSteps));
    return entries;
  }

  /// Emits a foreach-nested loop in the inline form the parser expects: the
  /// loop controller's id/name plus the loop's maxIterations/gates and its
  /// body (and optional finalizer) steps nested under `steps:`.
  List<MapEntry<String, dynamic>> _inlineLoopToOrderedMap(
    WorkflowStep? controller,
    WorkflowLoop loop,
    Map<String, WorkflowStep> stepsById,
  ) {
    final entries = <MapEntry<String, dynamic>>[
      MapEntry('id', loop.id),
      MapEntry('name', controller?.name ?? loop.id),
      MapEntry('type', 'loop'),
      MapEntry('maxIterations', loop.maxIterations),
    ];
    if (loop.entryGate != null) entries.add(MapEntry('entryGate', loop.entryGate));
    entries.add(MapEntry('exitGate', loop.exitGate));
    if (loop.onMaxIterations != WorkflowLoop.onMaxIterationsFail) {
      entries.add(MapEntry('onMaxIterations', loop.onMaxIterations));
    }
    final body = <dynamic>[];
    for (final stepId in loop.steps) {
      final step = stepsById[stepId];
      if (step != null) body.add(_stepToOrderedMap(step));
    }
    entries.add(MapEntry('steps', body));
    if (loop.finally_ != null) {
      final finalizer = stepsById[loop.finally_!];
      if (finalizer != null) entries.add(MapEntry('finally', _stepToOrderedMap(finalizer)));
    }
    return entries;
  }

  List<MapEntry<String, dynamic>> _stepToOrderedMap(WorkflowStep step) {
    final entries = <MapEntry<String, dynamic>>[MapEntry('id', step.id), MapEntry('name', step.name)];
    if (step.taskType != WorkflowTaskType.agent) {
      entries.add(MapEntry('type', step.taskType.toJson()));
    }
    if (step.skill != null) entries.add(MapEntry('skill', step.skill));
    if (step.prompts != null) {
      final prompts = step.prompts!;
      entries.add(MapEntry('prompt', prompts.length == 1 ? prompts.first : prompts));
    }
    if (step.provider != null) entries.add(MapEntry('provider', step.provider));
    if (step.model != null) entries.add(MapEntry('model', step.model));
    if (step.effort != null) entries.add(MapEntry('effort', step.effort));
    if (step.gatingSeverity != null) entries.add(MapEntry('gatingSeverity', step.gatingSeverity));
    if (step.timeoutSeconds != null) entries.add(MapEntry('timeout', step.timeoutSeconds));
    if (step.parallel) entries.add(MapEntry('parallel', true));
    if (step.gate != null) entries.add(MapEntry('gate', step.gate));
    if (step.entryGate != null) entries.add(MapEntry('entryGate', step.entryGate));
    if (step.inputs.isNotEmpty) entries.add(MapEntry('inputs', step.inputs.toList()));
    if (step.aggregateReviews != null) {
      entries.add(MapEntry('aggregateReviews', step.aggregateReviews!.toList()));
    }
    if (step.outputs != null && step.outputs!.isNotEmpty) {
      entries.add(MapEntry('outputs', step.outputs!.map((k, v) => MapEntry(k, v.toJson()))));
    }
    if (step.maxTokens != null) entries.add(MapEntry('maxTokens', step.maxTokens));
    if (step.maxRetries != null) entries.add(MapEntry('maxRetries', step.maxRetries));
    if (step.allowedTools != null) entries.add(MapEntry('allowedTools', step.allowedTools!.toList()));
    if (step.mapOver != null) entries.add(MapEntry('map_over', step.mapOver));
    if (step.mapAlias != null) entries.add(MapEntry('as', step.mapAlias));
    if (step.maxParallel != null) entries.add(MapEntry('max_parallel', step.maxParallel));
    if (step.maxItems != null) entries.add(MapEntry('max_items', step.maxItems));
    // Foreach controllers are emitted via [_foreachControllerToOrderedMap]
    // (inline form with nested steps). If we reach here with a foreach
    // controller, something mis-routed — drop the stale ID list rather than
    // emit an unparseable shape.
    if (step.continueSession != null) {
      entries.add(MapEntry('continueSession', step.continueSession == '@previous' ? true : step.continueSession));
    }
    if (step.onError != null) entries.add(MapEntry('onError', step.onError!.yamlName));
    if (step.workdir != null) entries.add(MapEntry('workdir', step.workdir));
    if (step.onFailure != OnFailurePolicy.fail) entries.add(MapEntry('onFailure', step.onFailure.yamlName));
    if (step.emitsOwnOutcome) entries.add(MapEntry('emitsOwnOutcome', true));
    if (!step.autoFrameContext) entries.add(MapEntry('auto_frame_context', false));
    if (step.workflowVariables.isNotEmpty) {
      entries.add(MapEntry('workflow_variables', step.workflowVariables.toList()));
    }
    return entries;
  }

  void _writeNode(StringBuffer buf, Object? node, {required int indent, required bool inList}) {
    if (node is List<MapEntry<String, dynamic>>) {
      _writeOrderedMap(buf, node, indent: indent, inList: inList);
      return;
    }
    if (node is Map) {
      _writeOrderedMap(
        buf,
        node.entries.map((e) => MapEntry<String, dynamic>(e.key.toString(), e.value)).toList(growable: false),
        indent: indent,
        inList: inList,
      );
      return;
    }
    if (node is List) {
      _writeList(buf, node, indent: indent);
      return;
    }
    _writeScalar(buf, node, indent: indent);
  }

  void _writeOrderedMap(
    StringBuffer buf,
    List<MapEntry<String, dynamic>> entries, {
    required int indent,
    required bool inList,
  }) {
    if (entries.isEmpty) {
      buf.writeln(inList ? '{}' : '{}');
      return;
    }
    var first = true;
    for (final entry in entries) {
      final key = entry.key;
      final value = entry.value;
      final prefix = (first && inList) ? '' : _spaces(indent);
      first = false;
      if (_isBlockContainer(value)) {
        buf.write('$prefix$key:');
        if (_isEmptyContainer(value)) {
          buf.writeln(' {}');
          continue;
        }
        buf.writeln();
        _writeNode(buf, value, indent: indent + 2, inList: false);
      } else {
        buf.write('$prefix$key: ');
        _writeScalar(buf, value, indent: indent);
      }
    }
  }

  void _writeList(StringBuffer buf, List<dynamic> list, {required int indent}) {
    if (list.isEmpty) {
      buf.writeln('${_spaces(indent)}[]');
      return;
    }
    for (final item in list) {
      final indentStr = _spaces(indent);
      if (_isBlockContainer(item)) {
        buf.write('$indentStr- ');
        _writeNode(buf, item, indent: indent + 2, inList: true);
      } else {
        buf.write('$indentStr- ');
        _writeScalar(buf, item, indent: indent);
      }
    }
  }

  void _writeScalar(StringBuffer buf, Object? value, {required int indent}) {
    if (value == null) {
      buf.writeln('null');
      return;
    }
    if (value is bool || value is int || value is double) {
      buf.writeln(value.toString());
      return;
    }
    if (value is String) {
      if (value.contains('\n')) {
        _writeBlockScalar(buf, value, indent: indent);
      } else {
        buf.writeln(_encodeFlowString(value));
      }
      return;
    }
    // Unknown scalar — fall back to quoted string.
    buf.writeln(_encodeFlowString(value.toString()));
  }

  /// Emits a multi-line string using the YAML `|` block scalar form so the
  /// body round-trips verbatim through `loadYaml`.
  void _writeBlockScalar(StringBuffer buf, String value, {required int indent}) {
    final childIndent = _spaces(indent + 2);
    final lines = value.split('\n');
    // Use `|-` when the value has no trailing newline so `loadYaml` preserves
    // the exact string; `|` on its own adds a trailing `\n`.
    final hasTrailingNewline = value.endsWith('\n');
    final header = hasTrailingNewline ? '|' : '|-';
    buf.writeln(header);
    final bodyLines = hasTrailingNewline ? lines.sublist(0, lines.length - 1) : lines;
    for (final line in bodyLines) {
      if (line.isEmpty) {
        buf.writeln();
      } else {
        buf.writeln('$childIndent$line');
      }
    }
  }

  String _encodeFlowString(String value) {
    if (value.isEmpty) return '""';
    // Quote when the string would parse as a non-string scalar or contains
    // YAML-significant characters. Err on the side of safety (better quoted
    // than mis-typed).
    final needsQuote =
        _ambiguousScalar(value) ||
        value.contains(': ') ||
        value.startsWith('- ') ||
        value.startsWith('?') ||
        value.startsWith('&') ||
        value.startsWith('*') ||
        value.startsWith('!') ||
        value.startsWith('#') ||
        value.startsWith('@') ||
        value.startsWith('|') ||
        value.startsWith('>') ||
        value.startsWith('{') ||
        value.startsWith('[') ||
        value.startsWith("'") ||
        value.startsWith('"') ||
        value.startsWith(',') ||
        value.contains(' #') ||
        value.trimRight() != value ||
        value.trimLeft() != value;
    if (!needsQuote) return value;
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  bool _ambiguousScalar(String value) {
    const reserved = {'true', 'false', 'null', 'yes', 'no', 'on', 'off', '~'};
    if (reserved.contains(value.toLowerCase())) return true;
    if (int.tryParse(value) != null) return true;
    if (double.tryParse(value) != null) return true;
    return false;
  }

  bool _isBlockContainer(Object? value) {
    if (value is List<MapEntry<String, dynamic>>) return true;
    if (value is Map) return true;
    if (value is List && value.isNotEmpty) return true;
    return false;
  }

  bool _isEmptyContainer(Object? value) {
    if (value is List<MapEntry<String, dynamic>>) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    if (value is List) return value.isEmpty;
    return false;
  }

  String _spaces(int count) => ' ' * count;
}
