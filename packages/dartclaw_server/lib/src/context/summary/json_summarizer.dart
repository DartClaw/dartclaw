import 'dart:convert';

import 'package:yaml/yaml.dart';

/// Extracts schema structure from JSON and YAML content.
abstract final class JsonSummarizer {
  static const _maxDepth = 4;
  static const _maxKeys = 200;

  /// Returns a formatted schema summary or null on parse failure.
  ///
  /// [isYaml] controls whether to parse as YAML instead of JSON.
  static String? summarize(String content, int estimatedTokens, {bool isYaml = false}) {
    dynamic parsed;
    final label = isYaml ? 'YAML' : 'JSON';
    try {
      if (isYaml) {
        final yamlDoc = loadYaml(content);
        parsed = _yamlToNative(yamlDoc);
      } else {
        parsed = jsonDecode(content);
      }
    } catch (_) {
      return null;
    }

    final buffer = StringBuffer();
    buffer.writeln('[Exploration summary — $label, ~${_fmt(estimatedTokens)} tokens]');
    buffer.writeln('Schema:');
    final keyCounter = [0]; // mutable accumulator across recursive _walk calls
    _walk(parsed, buffer, 1, 0, keyCounter: keyCounter, maxKeys: _maxKeys);
    buffer.writeln();
    buffer.write(
      '[Full content available — ${_fmt(estimatedTokens)} tokens. '
      'Use Read tool to access specific sections]',
    );
    return buffer.toString();
  }

  static void _walk(
    dynamic node,
    StringBuffer buf,
    int indent,
    int depth, {
    required List<int> keyCounter,
    required int maxKeys,
  }) {
    if (depth >= _maxDepth) return;
    final pad = '  ' * indent;

    if (node is Map) {
      var count = 0;
      for (final entry in node.entries) {
        if (keyCounter[0] >= maxKeys) {
          final remaining = node.length - count;
          if (remaining > 0) buf.writeln('$pad... and $remaining more');
          break;
        }
        final key = entry.key;
        final val = entry.value;
        keyCounter[0]++;
        count++;
        if (val is Map) {
          buf.writeln('$pad$key: Object');
          _walk(val, buf, indent + 1, depth + 1, keyCounter: keyCounter, maxKeys: maxKeys);
        } else if (val is List) {
          buf.writeln('$pad$key: Array[${val.length}]');
          if (val.isNotEmpty) {
            final first = val.first;
            if (first is Map || first is List) {
              _walk(first, buf, indent + 1, depth + 1, keyCounter: keyCounter, maxKeys: maxKeys);
            } else {
              buf.writeln('${' ' * ((indent + 1) * 2)}[0]: ${_typeName(first)}');
            }
          }
        } else {
          buf.writeln('$pad$key: ${_typeName(val)}');
        }
      }
    } else if (node is List) {
      if (node.isEmpty) {
        buf.writeln('$pad(empty array)');
        return;
      }
      final first = node.first;
      if (first is Map || first is List) {
        buf.writeln('$pad[0]: ${first is Map ? 'Object' : 'Array'}');
        _walk(first, buf, indent + 1, depth + 1, keyCounter: keyCounter, maxKeys: maxKeys);
      } else {
        buf.writeln('$pad[0]: ${_typeName(first)}');
      }
    } else {
      buf.writeln('$pad${_typeName(node)}');
    }
  }

  static String _typeName(dynamic val) {
    if (val == null) return 'null';
    if (val is bool) return 'bool';
    if (val is int) return 'number';
    if (val is double) return 'number';
    if (val is String) return 'string';
    if (val is List) return 'Array[${val.length}]';
    if (val is Map) return 'Object';
    return val.runtimeType.toString();
  }

  static dynamic _yamlToNative(dynamic node) {
    if (node is YamlMap) {
      return {for (final e in node.entries) e.key.toString(): _yamlToNative(e.value)};
    }
    if (node is YamlList) {
      return [for (final e in node) _yamlToNative(e)];
    }
    return node;
  }

  static String _fmt(int n) {
    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(1).replaceAll('.0', '')}K';
    }
    return n.toString();
  }
}
