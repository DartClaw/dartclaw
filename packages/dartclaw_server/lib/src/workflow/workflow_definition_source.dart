import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowDefinition, WorkflowVariable;

/// Summary projection of a workflow definition — enough for browsing and
/// selection without loading full prompt bodies.
typedef WorkflowSummary = ({
  String name,
  String description,
  int stepCount,
  bool hasLoops,
  int? maxTokens,
  Map<String, WorkflowVariable> variables,
});

/// Abstraction for looking up workflow definitions by name.
///
/// Separates summary listing (discovery) from full-definition fetching (detail).
/// Listing surfaces use [listSummaries] to stay lightweight; execution paths
/// use [getByName] when the full definition (including prompt bodies) is needed.
abstract interface class WorkflowDefinitionSource {
  /// Returns the full definition with [name], or null if not found.
  ///
  /// Use for workflow execution and detail display. Includes all step prompts.
  WorkflowDefinition? getByName(String name);

  /// Returns summary metadata for all available definitions.
  ///
  /// Summaries are safe for listing and picker surfaces — they contain
  /// descriptions and variable hints but never eager-load prompt bodies.
  List<WorkflowSummary> listSummaries();
}

/// Simple in-memory implementation for testing and initial wiring.
///
/// Populated at construction time. Immutable after creation.
class InMemoryDefinitionSource implements WorkflowDefinitionSource {
  final Map<String, WorkflowDefinition> _definitions;

  InMemoryDefinitionSource(List<WorkflowDefinition> definitions)
    : _definitions = {for (final d in definitions) d.name: d};

  @override
  WorkflowDefinition? getByName(String name) => _definitions[name];

  @override
  List<WorkflowSummary> listSummaries() => _definitions.values
      .map(
        (d) => (
          name: d.name,
          description: d.description,
          stepCount: d.steps.length,
          hasLoops: d.loops.isNotEmpty,
          maxTokens: d.maxTokens,
          variables: d.variables,
        ),
      )
      .toList();
}
