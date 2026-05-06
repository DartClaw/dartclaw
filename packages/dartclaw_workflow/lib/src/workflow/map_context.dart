/// Carries the per-iteration state for a map/fan-out step.
///
/// Passed to [WorkflowTemplateEngine.resolveWithMap] to resolve `{{map.*}}`
/// (and optional `{{<alias>.*}}`) references and `{{context.key[map.index]}}`
/// (or `{{context.key[<alias>.index]}}`) template references within a map
/// step's prompt templates.
class MapContext {
  /// The current iteration item. May be a [Map], [List], [String], [num], or [bool].
  final Object item;

  /// The 0-based index of the current iteration within the collection.
  final int index;

  /// The total number of items in the collection.
  final int length;

  /// Optional author-supplied loop variable name, sourced from the controller
  /// step's `as:` field.
  ///
  /// When null, only the legacy `map.*` prefix binds. When set, templates may
  /// also use `{{<alias>.item}}` / `{{<alias>.index}}` / etc., while `map.*`
  /// continues to work for backward compatibility.
  final String? alias;

  /// Parent iteration context for nested `foreach` execution.
  ///
  /// Today nested foreach is not wired through the executor, so this is always
  /// null in practice. The field is reserved so the template engine can
  /// eventually resolve outer aliases without a call-chain signature change.
  final MapContext? parent;

  const MapContext({required this.item, required this.index, required this.length, this.alias, this.parent});

  /// Extracts a non-empty `id` field from the current item when present.
  String? get itemId {
    final currentItem = item;
    if (currentItem is! Map) return null;
    final id = currentItem['id'];
    if (id is! String) return null;
    final normalizedId = id.trim();
    return normalizedId.isEmpty ? null : normalizedId;
  }
}
