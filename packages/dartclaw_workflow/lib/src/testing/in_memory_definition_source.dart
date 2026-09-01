import '../workflow/workflow_definition.dart';
import '../workflow/workflow_definition_resolver.dart';
import '../workflow/workflow_definition_source.dart';

/// In-memory [WorkflowDefinitionSource] for consuming test suites.
///
/// Populated at construction time. Immutable after creation.
class InMemoryDefinitionSource implements WorkflowDefinitionSource {
  final Map<String, WorkflowDefinition> _definitions;
  static const _resolver = WorkflowDefinitionResolver();

  new(List<WorkflowDefinition> definitions) : _definitions = {for (final d in definitions) d.name: d};

  @override
  WorkflowDefinition? getByName(String name) => _definitions[name];

  @override
  String? authoredYaml(String name) {
    final definition = _definitions[name];
    if (definition == null) return null;
    return _resolver.emitYaml(definition);
  }

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
