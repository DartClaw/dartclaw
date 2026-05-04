/// Persistent key-value map shared between workflow steps.
///
/// Stores variable bindings, step outputs, and loop iteration state.
/// This is a pure in-memory data structure — the executor handles
/// atomic persistence to disk.
class WorkflowContext {
  final Map<String, dynamic> _data;
  final Map<String, String> _variables;
  final Map<String, String> _systemVariables;

  WorkflowContext({Map<String, dynamic>? data, Map<String, String>? variables, Map<String, String>? systemVariables})
    : _data = Map.of(data ?? {}),
      _variables = Map.unmodifiable(variables ?? {}),
      _systemVariables = Map.of(systemVariables ?? const {});

  dynamic operator [](String key) => _data[key];

  void operator []=(String key, dynamic value) => _data[key] = value;

  String? variable(String name) => _variables[name];

  String? systemVariable(String name) => _systemVariables[name];

  Map<String, String> get variables => _variables;

  Map<String, String> get systemVariables => Map.unmodifiable(_systemVariables);

  Map<String, dynamic> get data => Map.unmodifiable(_data);

  void mergeSystemVariables(Map<String, String> systemVariables) {
    _systemVariables.addAll(systemVariables);
  }

  /// Merges step outputs into the context.
  void merge(Map<String, dynamic> outputs) => _data.addAll(outputs);

  /// Removes a context value when retry or remediation needs to clear stale state.
  void remove(String key) => _data.remove(key);

  int? loopIteration(String loopId) => _data['loop.$loopId.iteration'] as int?;

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
