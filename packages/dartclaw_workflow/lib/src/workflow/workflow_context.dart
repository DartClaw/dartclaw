/// Persistent key-value map shared between workflow steps.
///
/// Stores variable bindings, step outputs, and loop iteration state.
/// This is a pure in-memory data structure — the executor handles
/// atomic persistence to disk.
class WorkflowContext {
  final Map<String, dynamic> _data;
  final Map<String, String> _variables;

  WorkflowContext({Map<String, dynamic>? data, Map<String, String>? variables})
    : _data = Map.of(data ?? {}),
      _variables = Map.unmodifiable(variables ?? {});

  /// Returns the value for [key], or null if not set.
  dynamic operator [](String key) => _data[key];

  /// Sets a context value.
  void operator []=(String key, dynamic value) => _data[key] = value;

  /// Returns the value of a workflow variable.
  String? variable(String name) => _variables[name];

  /// Returns all variable bindings.
  Map<String, String> get variables => _variables;

  /// Returns the full context data as an unmodifiable view.
  Map<String, dynamic> get data => Map.unmodifiable(_data);

  /// Merges step outputs into the context.
  void merge(Map<String, dynamic> outputs) => _data.addAll(outputs);

  /// Returns the current loop iteration for [loopId], or null if not in a loop.
  int? loopIteration(String loopId) => _data['loop.$loopId.iteration'] as int?;

  /// Sets the loop iteration counter.
  void setLoopIteration(String loopId, int iteration) {
    _data['loop.$loopId.iteration'] = iteration;
  }

  /// Serializes to JSON for persistence.
  Map<String, dynamic> toJson() => {
    'data': Map<String, dynamic>.from(_data),
    'variables': Map<String, String>.from(_variables),
  };

  /// Deserializes from persisted JSON.
  factory WorkflowContext.fromJson(Map<String, dynamic> json) => WorkflowContext(
    data: (json['data'] as Map?)?.cast<String, dynamic>(),
    variables: (json['variables'] as Map?)?.cast<String, String>(),
  );
}
