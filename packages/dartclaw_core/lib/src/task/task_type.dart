/// High-level task category.
enum TaskType {
  /// Task centered on code changes or software implementation.
  coding,

  /// Task focused on gathering facts, sources, or background material.
  research,

  /// Task aimed at producing prose or structured written output.
  writing,

  /// Task that inspects existing state and reports findings.
  analysis,

  /// Task that performs operational or workflow automation.
  automation,

  /// Task type defined by caller-specific conventions.
  custom,
}
