import 'dart:convert';

final class WorkflowSchemaChecker {
  final Map<String, Object?> root;

  const new(this.root);

  List<String> validate(Object? value) => _check(root, value, r'$');

  List<String> validateNode(Map<String, Object?> schema, Object? value, {String path = r'$'}) =>
      _check(schema, value, path);

  List<String> _check(Map<String, Object?> schema, Object? value, String path) {
    final reference = schema[r'$ref'];
    if (reference is String) return _check(_resolve(reference), value, path);

    final diagnostics = <String>[];
    final type = schema['type'];
    if (type != null && !_matchesType(value, type)) {
      diagnostics.add('$path: expected $type');
      return diagnostics;
    }
    if (schema.containsKey('const') && !_equal(value, schema['const'])) {
      diagnostics.add('$path: expected ${jsonEncode(schema['const'])}');
    }
    final values = schema['enum'];
    if (values is List<Object?> && !values.any((candidate) => _equal(candidate, value))) {
      diagnostics.add('$path: expected one of ${jsonEncode(values)}');
    }

    if (value is Map<Object?, Object?>) {
      final required = schema['required'];
      if (required is List<Object?>) {
        for (final name in required.cast<String>()) {
          if (!value.containsKey(name)) diagnostics.add('$path.$name: required');
        }
      }
      final properties = schema['properties'];
      if (properties is Map<Object?, Object?>) {
        for (final entry in value.entries) {
          final name = '${entry.key}';
          final property = properties[name];
          if (property is Map<Object?, Object?>) {
            diagnostics.addAll(_check(Map<String, Object?>.from(property), entry.value, '$path.$name'));
          } else {
            final additional = schema['additionalProperties'];
            if (additional == false) {
              diagnostics.add('$path.$name: unknown property');
            } else if (additional is Map<Object?, Object?>) {
              diagnostics.addAll(_check(Map<String, Object?>.from(additional), entry.value, '$path.$name'));
            }
          }
        }
      } else if (schema['additionalProperties'] case final Map<Object?, Object?> additional) {
        for (final entry in value.entries) {
          diagnostics.addAll(_check(Map<String, Object?>.from(additional), entry.value, '$path.${entry.key}'));
        }
      }
    }

    if (value is List<Object?>) {
      final minItems = schema['minItems'];
      if (minItems is int && value.length < minItems) diagnostics.add('$path: expected at least $minItems items');
      if (schema['items'] case final Map<Object?, Object?> items) {
        for (var index = 0; index < value.length; index++) {
          diagnostics.addAll(_check(Map<String, Object?>.from(items), value[index], '$path[$index]'));
        }
      }
    }

    if (schema['allOf'] case final List<Object?> branches) {
      for (final branch in branches.cast<Map<Object?, Object?>>()) {
        diagnostics.addAll(_check(Map<String, Object?>.from(branch), value, path));
      }
    }
    if (schema['anyOf'] case final List<Object?> branches) {
      if (!branches.cast<Map<Object?, Object?>>().any(
        (branch) => _check(Map<String, Object?>.from(branch), value, path).isEmpty,
      )) {
        diagnostics.add('$path: did not match any allowed shape');
      }
    }
    if (schema['oneOf'] case final List<Object?> branches) {
      final branchDiagnostics = [
        for (final branch in branches.cast<Map<Object?, Object?>>())
          _check(Map<String, Object?>.from(branch), value, path),
      ];
      final matches = branchDiagnostics.where((result) => result.isEmpty).length;
      if (matches != 1) diagnostics.add('$path: expected exactly one allowed shape, matched $matches');
      if (matches == 0) diagnostics.addAll(branchDiagnostics.expand((result) => result));
    }
    if (schema['not'] case final Map<Object?, Object?> excluded) {
      if (_check(Map<String, Object?>.from(excluded), value, path).isEmpty) {
        diagnostics.add('$path: matched a forbidden shape');
      }
    }
    if (schema['if'] case final Map<Object?, Object?> condition) {
      final matches = _check(Map<String, Object?>.from(condition), value, path).isEmpty;
      final selected = matches ? schema['then'] : schema['else'];
      if (selected is Map<Object?, Object?>) {
        diagnostics.addAll(_check(Map<String, Object?>.from(selected), value, path));
      }
    }
    return diagnostics;
  }

  Map<String, Object?> _resolve(String reference) {
    if (!reference.startsWith('#/')) throw StateError('Unsupported reference: $reference');
    Object? node = root;
    for (final segment in reference.substring(2).split('/')) {
      if (node is! Map<Object?, Object?> || !node.containsKey(segment)) {
        throw StateError('Unresolved reference: $reference');
      }
      node = node[segment];
    }
    return Map<String, Object?>.from(node! as Map<Object?, Object?>);
  }

  bool _matchesType(Object? value, Object type) {
    final types = type is List<Object?> ? type.cast<String>() : [type as String];
    return types.any(
      (candidate) => switch (candidate) {
        'array' => value is List<Object?>,
        'boolean' => value is bool,
        'integer' => value is int,
        'null' => value == null,
        'number' => value is num,
        'object' => value is Map<Object?, Object?>,
        'string' => value is String,
        _ => throw StateError('Unsupported type: $candidate'),
      },
    );
  }

  bool _equal(Object? left, Object? right) => jsonEncode(left) == jsonEncode(right);
}

Set<String> emittedSchemaKeywords(Map<String, Object?> root) {
  final found = <String>{};

  void visit(Map<String, Object?> schema) {
    found.addAll(schema.keys);
    for (final key in const ['not', 'if', 'then', 'else', 'items', 'additionalProperties']) {
      if (schema[key] case final Map<Object?, Object?> child) visit(Map<String, Object?>.from(child));
    }
    for (final key in const ['allOf', 'anyOf', 'oneOf']) {
      if (schema[key] case final List<Object?> children) {
        for (final child in children.cast<Map<Object?, Object?>>()) {
          visit(Map<String, Object?>.from(child));
        }
      }
    }
    for (final key in const ['properties', r'$defs']) {
      if (schema[key] case final Map<Object?, Object?> children) {
        for (final child in children.values.whereType<Map<Object?, Object?>>()) {
          visit(Map<String, Object?>.from(child));
        }
      }
    }
  }

  visit(root);
  return found;
}

Set<String> emittedSchemaTypes(Map<String, Object?> root) {
  final types = <String>{};

  void visit(Map<String, Object?> schema) {
    final type = schema['type'];
    if (type is String) types.add(type);
    if (type is List<Object?>) types.addAll(type.cast<String>());
    for (final key in const ['not', 'if', 'then', 'else', 'items', 'additionalProperties']) {
      if (schema[key] case final Map<Object?, Object?> child) visit(Map<String, Object?>.from(child));
    }
    for (final key in const ['allOf', 'anyOf', 'oneOf']) {
      if (schema[key] case final List<Object?> children) {
        for (final child in children.cast<Map<Object?, Object?>>()) {
          visit(Map<String, Object?>.from(child));
        }
      }
    }
    for (final key in const ['properties', r'$defs']) {
      if (schema[key] case final Map<Object?, Object?> children) {
        for (final child in children.values.whereType<Map<Object?, Object?>>()) {
          visit(Map<String, Object?>.from(child));
        }
      }
    }
  }

  visit(root);
  return types;
}
