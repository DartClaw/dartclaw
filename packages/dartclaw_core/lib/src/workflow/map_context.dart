/// Carries the per-iteration state for a map/fan-out step.
///
/// Passed to [WorkflowTemplateEngine.resolveWithMap] to resolve `{{map.*}}`
/// and `{{context.key[map.index]}}` template references within a map step's
/// prompt templates.
class MapContext {
  /// The current iteration item. May be a [Map], [List], [String], [num], or [bool].
  final Object item;

  /// The 0-based index of the current iteration within the collection.
  final int index;

  /// The total number of items in the collection.
  final int length;

  const MapContext({required this.item, required this.index, required this.length});
}
