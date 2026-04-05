import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowDefinition;

/// Abstraction for looking up workflow definitions by name.
///
/// Decouples the API routes from the concrete WorkflowRegistry (S06).
/// S05 provides a minimal in-memory implementation for testing and
/// initial wiring. S06 replaces this with the full registry.
abstract interface class WorkflowDefinitionSource {
  /// Returns the definition with [name], or null if not found.
  WorkflowDefinition? getByName(String name);

  /// Returns all available definitions.
  List<WorkflowDefinition> listAll();
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
  List<WorkflowDefinition> listAll() => _definitions.values.toList();
}
