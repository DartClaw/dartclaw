import 'dart:convert';

import 'package:logging/logging.dart';

import 'map_context.dart';
import 'workflow_context.dart';

/// Resolves `{{variable}}` and `{{context.key}}` placeholders in templates.
///
/// Simple substitution only — no Handlebars conditionals.
class WorkflowTemplateEngine {
  static final _log = Logger('WorkflowTemplateEngine');
  static final _pattern = RegExp(r'\{\{([^}]+)\}\}');
  // Captures `<key>[<prefix>.index]` and optional `.field[.sub…]` tail.
  // `<prefix>` is `map` for legacy references or a user-declared `as:` alias.
  static final _indexedContextPattern = RegExp(r'^([\w]+)\[([A-Za-z_][\w]*)\.index\](?:\.(.+))?$');
  static final Object _missingIndexedElement = Object();

  /// Aliases reserved at the template level — parser must reject `as:` values
  /// that collide with these, since they already have fixed meanings.
  static const reservedMapAliases = {'map', 'context', 'workflow'};

  /// Resolves all template references in [template] against [context].
  ///
  /// - `{{VARIABLE}}` resolves against workflow variables
  /// - `{{workflow.KEY}}` resolves against render-only workflow system variables
  /// - `{{context.KEY}}` resolves against accumulated context data
  /// - Missing variables throw [ArgumentError] (fail-fast at start time)
  /// - Missing context keys resolve to empty string with a log warning
  String resolve(String template, WorkflowContext context) {
    return template.replaceAllMapped(_pattern, (match) {
      final ref = match.group(1)!.trim();
      if (ref.startsWith('context.')) {
        final key = ref.substring('context.'.length);
        final value = context[key];
        if (value == null) {
          _log.warning(
            'Template reference {{$ref}} resolved to empty string '
            '(key "$key" not in context)',
          );
          return '';
        }
        return value.toString();
      }
      if (ref.startsWith('workflow.')) {
        final value = context.systemVariable(ref);
        if (value == null) {
          throw ArgumentError('Template references undefined workflow system variable: {{$ref}}');
        }
        return value;
      }
      final value = context.variable(ref);
      if (value == null) {
        throw ArgumentError('Template references undefined variable: {{$ref}}');
      }
      return value;
    });
  }

  /// Resolves all template references in [template] against [context] and [mapCtx].
  ///
  /// Extends [resolve] with support for map-iteration references:
  /// - `{{map.item}}` — current item (JSON-encoded if Map, toString otherwise)
  /// - `{{map.item.field}}` — field access on Map item (fail-fast if item is scalar)
  /// - `{{map.item.a.b.…}}` — nested traversal (up to 10 segments after `map.item`)
  /// - `{{map.index}}` — 0-based iteration index
  /// - `{{map.display_index}}` — 1-based iteration index for author-facing text
  /// - `{{map.length}}` — total collection size
  /// - `{{context.key[map.index]}}` — indexed lookup into a List-typed context value
  ///
  /// When the controller step declares an `as:` alias, the same references are
  /// also reachable under that prefix — e.g. `{{story.item.spec_path}}`,
  /// `{{story.display_index}}`, `{{context.items[story.index]}}` — while the
  /// legacy `map.*` references continue to resolve against the same iteration.
  ///
  /// When [mapCtx] is null, delegates to [resolve] (backward compat).
  String resolveWithMap(String template, WorkflowContext context, MapContext? mapCtx) {
    if (mapCtx == null) return resolve(template, context);
    final alias = mapCtx.alias;
    return template.replaceAllMapped(_pattern, (match) {
      final ref = match.group(1)!.trim();

      // Legacy `map.*` — always binds to the innermost context.
      if (ref == 'map' || ref.startsWith('map.')) {
        return _resolveMapRef(ref, 'map', mapCtx);
      }

      // Author-supplied alias (e.g. `as: story` → `{{story.item}}`).
      if (alias != null && (ref == alias || ref.startsWith('$alias.'))) {
        return _resolveMapRef(ref, alias, mapCtx);
      }

      // context.key[<prefix>.index] or context.key[<prefix>.index].field
      if (ref.startsWith('context.')) {
        final keyPart = ref.substring('context.'.length);
        final indexedMatch = _indexedContextPattern.firstMatch(keyPart);
        if (indexedMatch != null) {
          final key = indexedMatch.group(1)!;
          final indexPrefix = indexedMatch.group(2)!;
          final dotSuffix = indexedMatch.group(3); // null if no dot-access suffix
          if (indexPrefix != 'map' && indexPrefix != alias) {
            _log.warning(
              'Indexed context reference {{$ref}}: unknown prefix "$indexPrefix" '
              '(expected "map" or the controller alias "${alias ?? '—'}") — '
              'resolving to empty string.',
            );
            return '';
          }
          return _resolveIndexedContext(key, dotSuffix, context, mapCtx);
        }
        // Plain context reference — use normal resolution
        final value = context[keyPart];
        if (value == null) {
          _log.warning(
            'Template reference {{$ref}} resolved to empty string '
            '(key "$keyPart" not in context)',
          );
          return '';
        }
        return value.toString();
      }

      if (ref.startsWith('workflow.')) {
        final value = context.systemVariable(ref);
        if (value == null) {
          throw ArgumentError('Template references undefined workflow system variable: {{$ref}}');
        }
        return value;
      }

      // Variable reference
      final value = context.variable(ref);
      if (value == null) {
        throw ArgumentError('Template references undefined variable: {{$ref}}');
      }
      return value;
    });
  }

  /// Resolves a `<prefix>.*` reference (where `<prefix>` is `"map"` or the
  /// controller's `as:` alias) using the current [MapContext].
  String _resolveMapRef(String ref, String prefix, MapContext mapCtx) {
    if (ref == prefix) {
      throw ArgumentError('Template reference {{$ref}}: "$prefix" alone has no value; did you mean {{$prefix.item}}?');
    }
    final suffix = ref.substring(prefix.length + 1); // strip "<prefix>."
    if (suffix == 'index') return mapCtx.index.toString();
    if (suffix == 'display_index') return (mapCtx.index + 1).toString();
    if (suffix == 'length') return mapCtx.length.toString();
    if (suffix == 'item') {
      final item = mapCtx.item;
      if (item is Map) return jsonEncode(item);
      return item.toString();
    }

    // <prefix>.item.field[.sub…] — dot notation, max 10 segments after `item.`
    if (suffix.startsWith('item.')) {
      final path = suffix.substring('item.'.length).split('.');
      if (path.length > 10) {
        throw ArgumentError('Template reference {{$ref}}: dot notation exceeds 10 levels after $prefix.item.');
      }
      final item = mapCtx.item;
      if (item is! Map) {
        throw ArgumentError(
          'Template reference {{$ref}}: dot access on non-Map item '
          '(item is ${item.runtimeType}). Only Map items support field access.',
        );
      }
      return _traverseMap(item, path, ref);
    }

    throw ArgumentError('Unknown map template reference: {{$ref}}');
  }

  /// Traverses nested Maps following [path] segments, starting at [root].
  String _traverseMap(Map<dynamic, dynamic> root, List<String> path, String originalRef) {
    Object? current = root;
    for (var i = 0; i < path.length; i++) {
      final segment = path[i];
      if (current is! Map) {
        throw ArgumentError(
          'Template reference {{$originalRef}}: intermediate value at segment '
          '"$segment" is not a Map (got ${current.runtimeType}).',
        );
      }
      current = current[segment];
    }

    if (current == null) return '';
    if (current is List) {
      // Array-typed field: render as bullet list
      return current.map((e) => '- $e').join('\n');
    }
    return current.toString();
  }

  /// Resolves `{{context.key[map.index]}}` or `{{context.key[map.index].field}}`.
  String _resolveIndexedContext(String key, String? dotSuffix, WorkflowContext context, MapContext mapCtx) {
    final raw = context[key];
    if (raw == null) {
      _log.warning(
        'Indexed context reference {{context.$key[map.index]}}: '
        'key "$key" not in context — resolving to empty string.',
      );
      return '';
    }
    final element = switch (raw) {
      final List<dynamic> list => _resolveIndexedListElement(key, list, mapCtx),
      final Map<dynamic, dynamic> map => _resolveIndexedMapElement(key, map, mapCtx),
      _ => _missingIndexedElement,
    };
    if (identical(element, _missingIndexedElement)) {
      _log.warning(
        'Indexed context reference {{context.$key[map.index]}}: '
        'value for "$key" could not be indexed (got ${raw.runtimeType}) — resolving to empty string.',
      );
      return '';
    }

    if (dotSuffix != null) {
      // Explicit dot-access: bypass auto-extraction, resolve named field
      final segments = dotSuffix.split('.');
      if (element is! Map) {
        _log.warning(
          'Indexed context reference {{context.$key[map.index].$dotSuffix}}: '
          'element is not a Map — resolving to empty string.',
        );
        return '';
      }
      return _traverseMap(element, segments, 'context.$key[map.index].$dotSuffix');
    }

    // Auto-extract .text from Map elements (supports S07 structured results)
    if (element is Map && element.containsKey('text')) {
      return element['text'].toString();
    }

    if (element == null) return '';
    return element.toString();
  }

  Object? _resolveIndexedListElement(String key, List<dynamic> raw, MapContext mapCtx) {
    final idx = mapCtx.index;
    if (idx < 0 || idx >= raw.length) {
      _log.warning(
        'Indexed context reference {{context.$key[map.index]}}: '
        'index $idx out of bounds for list of length ${raw.length} — resolving to empty string.',
      );
      return _missingIndexedElement;
    }
    return raw[idx];
  }

  Object? _resolveIndexedMapElement(String key, Map<dynamic, dynamic> raw, MapContext mapCtx) {
    if (raw.length == 1 && raw.values.first is List<dynamic>) {
      return _resolveIndexedListElement(key, raw.values.first as List<dynamic>, mapCtx);
    }

    final item = mapCtx.item;
    if (item is Map<dynamic, dynamic>) {
      final itemId = item['id'];
      if (itemId != null && raw.containsKey(itemId)) {
        return raw[itemId];
      }
    }

    if (raw.containsKey(mapCtx.index)) {
      return raw[mapCtx.index];
    }

    final stringIndex = mapCtx.index.toString();
    if (raw.containsKey(stringIndex)) {
      return raw[stringIndex];
    }

    return _missingIndexedElement;
  }

  /// Extracts all variable references (non-context) from [template].
  ///
  /// Used by validation to check that all referenced variables are declared.
  ///
  /// Pass [mapAliases] with the set of loop variable names (`as:` values) that
  /// are in scope for the template's step. Refs matching any declared alias
  /// are excluded so that `{{story.item.path}}` is not mistaken for an
  /// undeclared `story` variable.
  Set<String> extractVariableReferences(String template, {Set<String>? mapAliases}) {
    return _pattern.allMatches(template).map((m) => m.group(1)!.trim()).where((ref) {
      if (ref.startsWith('context.')) return false;
      if (ref.startsWith('workflow.')) return false;
      if (ref == 'map' || ref.startsWith('map.')) return false;
      if (mapAliases != null) {
        for (final alias in mapAliases) {
          if (ref == alias || ref.startsWith('$alias.')) return false;
        }
      }
      return true;
    }).toSet();
  }

  /// Extracts all context key references from [template].
  Set<String> extractContextReferences(String template) {
    return _pattern.allMatches(template).map((m) => m.group(1)!.trim()).where((ref) => ref.startsWith('context.')).map((
      ref,
    ) {
      final keyPart = ref.substring('context.'.length);
      // Strip `[<prefix>.index]` suffix and dot-access if present
      final bracketIdx = keyPart.indexOf('[');
      return bracketIdx >= 0 ? keyPart.substring(0, bracketIdx) : keyPart;
    }).toSet();
  }
}
