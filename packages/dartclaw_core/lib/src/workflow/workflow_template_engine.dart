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
  static final _indexedContextPattern = RegExp(r'^([\w]+)\[map\.index\](?:\.(.+))?$');

  /// Resolves all template references in [template] against [context].
  ///
  /// - `{{VARIABLE}}` resolves against workflow variables
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
  /// - `{{map.item.a.b}}` / `{{map.item.a.b.c}}` — nested traversal (max 3 levels)
  /// - `{{map.index}}` — 0-based iteration index
  /// - `{{map.length}}` — total collection size
  /// - `{{context.key[map.index]}}` — indexed lookup into a List-typed context value
  ///
  /// When [mapCtx] is null, delegates to [resolve] (backward compat).
  String resolveWithMap(String template, WorkflowContext context, MapContext? mapCtx) {
    if (mapCtx == null) return resolve(template, context);
    return template.replaceAllMapped(_pattern, (match) {
      final ref = match.group(1)!.trim();

      // map.* references
      if (ref.startsWith('map.')) {
        return _resolveMapRef(ref, mapCtx);
      }

      // context.key[map.index] or context.key[map.index].field references
      if (ref.startsWith('context.')) {
        final keyPart = ref.substring('context.'.length);
        final indexedMatch = _indexedContextPattern.firstMatch(keyPart);
        if (indexedMatch != null) {
          final key = indexedMatch.group(1)!;
          final dotSuffix = indexedMatch.group(2); // null if no dot-access suffix
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

      // Variable reference
      final value = context.variable(ref);
      if (value == null) {
        throw ArgumentError('Template references undefined variable: {{$ref}}');
      }
      return value;
    });
  }

  /// Resolves a `map.*` reference using the current [MapContext].
  String _resolveMapRef(String ref, MapContext mapCtx) {
    if (ref == 'map.index') return mapCtx.index.toString();
    if (ref == 'map.length') return mapCtx.length.toString();
    if (ref == 'map.item') {
      final item = mapCtx.item;
      if (item is Map) return jsonEncode(item);
      return item.toString();
    }

    // map.item.field[.sub[.sub2]] — dot notation, max 3 levels after map.item
    if (ref.startsWith('map.item.')) {
      final path = ref.substring('map.item.'.length).split('.');
      if (path.length > 3) {
        throw ArgumentError(
          'Template reference {{$ref}}: dot notation exceeds 3 levels after map.item.',
        );
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
  String _resolveIndexedContext(
    String key,
    String? dotSuffix,
    WorkflowContext context,
    MapContext mapCtx,
  ) {
    final raw = context[key];
    if (raw == null) {
      _log.warning(
        'Indexed context reference {{context.$key[map.index]}}: '
        'key "$key" not in context — resolving to empty string.',
      );
      return '';
    }
    if (raw is! List) {
      _log.warning(
        'Indexed context reference {{context.$key[map.index]}}: '
        'value for "$key" is not a List (got ${raw.runtimeType}) — resolving to empty string.',
      );
      return '';
    }
    final idx = mapCtx.index;
    if (idx < 0 || idx >= raw.length) {
      _log.warning(
        'Indexed context reference {{context.$key[map.index]}}: '
        'index $idx out of bounds for list of length ${raw.length} — resolving to empty string.',
      );
      return '';
    }
    final element = raw[idx];

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

  /// Extracts all variable references (non-context) from [template].
  ///
  /// Used by validation to check that all referenced variables are declared.
  Set<String> extractVariableReferences(String template) {
    return _pattern
        .allMatches(template)
        .map((m) => m.group(1)!.trim())
        .where((ref) => !ref.startsWith('context.') && !ref.startsWith('map.'))
        .toSet();
  }

  /// Extracts all context key references from [template].
  Set<String> extractContextReferences(String template) {
    return _pattern
        .allMatches(template)
        .map((m) => m.group(1)!.trim())
        .where((ref) => ref.startsWith('context.'))
        .map((ref) {
          final keyPart = ref.substring('context.'.length);
          // Strip [map.index] suffix and dot-access if present
          final bracketIdx = keyPart.indexOf('[');
          return bracketIdx >= 0 ? keyPart.substring(0, bracketIdx) : keyPart;
        })
        .toSet();
  }
}
