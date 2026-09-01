import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

/// Builds the closed input schema every host-registered MCP tool declares.
Map<String, dynamic> toolSchema(Map<String, dynamic> properties, List<String> required) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

/// A successful tool result carrying [payload] as JSON.
ToolResult toolJson(Map<String, Object?> payload) => ToolResult.text(jsonEncode(payload));

/// A handled tool refusal carrying [reason], [message] and any [details].
ToolResult toolError(String reason, String message, [Map<String, Object?> details = const {}]) =>
    ToolResult.error(jsonEncode({'reason': reason, 'message': message, ...details}));

/// Checks [args] against the closed [schema] the tool declares, failing on the
/// first violation.
///
/// The dispatch seam already refuses arguments the schema does not name, so
/// this pass owns only what it does not check: required properties, declared
/// types, enumerated values, integer bounds, and the declared element type of
/// an array or free-keyed object. Fails closed — an argument that does not
/// satisfy the declared contract refuses the call rather than being repaired or
/// defaulted, and a declared type this pass cannot check is itself a refusal.
ToolResult? validateToolArguments(Map<String, dynamic> schema, Map<String, dynamic> args) {
  final properties = (schema['properties'] as Map).cast<String, dynamic>();
  for (final required in (schema['required'] as List).cast<String>()) {
    if (!args.containsKey(required)) return toolError('invalid_request', '$required is required');
  }
  for (final MapEntry(key: property, value: spec) in properties.entries) {
    if (!args.containsKey(property)) continue;
    final value = args[property];
    final declared = (spec as Map)['type'];
    final typeError = switch (declared) {
      'string' => value is String && value.trim().isNotEmpty ? null : '$property must be a non-empty string',
      'boolean' => value is bool ? null : '$property must be a boolean',
      'integer' => value is int ? null : '$property must be an integer',
      'object' => value is Map ? _objectValueError(property, spec, value) : '$property must be an object',
      'array' => value is List ? _arrayItemError(property, spec, value) : '$property must be an array',
      // A declared type this pass cannot check would otherwise pass unvalidated,
      // which is the opposite of what the contract above promises.
      _ => '$property declares a type this tool cannot validate',
    };
    if (typeError != null) return toolError('invalid_request', typeError);

    final allowed = spec['enum'] as List?;
    if (allowed != null && !allowed.contains(value)) {
      return toolError('invalid_request', '$property must be one of: ${allowed.join(', ')}');
    }
    if (value is int) {
      final minimum = spec['minimum'] as int?;
      final maximum = spec['maximum'] as int?;
      if (minimum != null && value < minimum) {
        return toolError('invalid_request', '$property must be at least $minimum');
      }
      if (maximum != null && value > maximum) {
        return toolError('invalid_request', '$property must be at most $maximum');
      }
    }
  }
  return null;
}

/// Refuses a free-keyed object whose values do not match the element type its
/// `additionalProperties` declares. An object that declares no element type
/// carries arbitrary values by contract and is left alone.
String? _objectValueError(String property, Map<Object?, Object?> spec, Map<Object?, Object?> value) {
  final element = spec['additionalProperties'];
  if (element is! Map) return null;
  final declared = element['type'];
  if (declared != 'string') return '$property declares an element type this tool cannot validate';
  for (final entry in value.entries) {
    if (entry.value is! String) return '$property values must be strings';
  }
  return null;
}

/// Refuses an array whose elements do not match the type its `items` declares.
String? _arrayItemError(String property, Map<Object?, Object?> spec, List<Object?> value) {
  final items = spec['items'];
  if (items is! Map) return null;
  final declared = items['type'];
  if (declared != 'string') return '$property declares an element type this tool cannot validate';
  for (final item in value) {
    if (item is! String || item.trim().isEmpty) return '$property entries must be non-empty strings';
  }
  final maxItems = spec['maxItems'] as int?;
  if (maxItems != null && value.length > maxItems) return '$property must hold at most $maxItems entries';
  return null;
}
