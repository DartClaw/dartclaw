import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:shelf/shelf.dart';

import 'api_helpers.dart';

/// Shared request-parsing and small utilities for the `session_*_routes.dart`
/// family. These helpers are public-within-package so each sibling router file
/// can reuse them without re-implementing body parsing or trimming.

const maxSendBodyBytes = 256 * 1024;

String? trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

/// Extracts a named field from form-urlencoded or JSON request body.
Future<({String? value, Response? error})> parseBodyField(Request request, String field) async {
  final parsed = await parseBodyFields(request);
  if (parsed.error != null) return (value: null, error: parsed.error);
  return (value: parsed.fields[field], error: null);
}

Future<({Map<String, String> fields, Response? error})> parseBodyFields(Request request) async {
  final ct = request.headers['content-type'] ?? '';
  if (ct.startsWith('application/x-www-form-urlencoded')) {
    final parsed = await readFormFields(request, maxBytes: maxSendBodyBytes);
    if (parsed.error != null) return (fields: const <String, String>{}, error: parsed.error);
    return (fields: {for (final entry in parsed.fields.entries) entry.key: entry.value.last}, error: null);
  }
  if (ct.startsWith('application/json')) {
    try {
      final bodyResult = await readRequestBody(request, maxBytes: maxSendBodyBytes);
      if (bodyResult.error != null) return (fields: const <String, String>{}, error: bodyResult.error);
      final body = bodyResult.body!;
      final json = jsonDecode(body) as Map<String, dynamic>;
      final fields = <String, String>{};
      for (final entry in json.entries) {
        final value = entry.value;
        if (value is String) {
          fields[entry.key] = value;
        } else if (value != null) {
          fields[entry.key] = jsonEncode(value);
        }
      }
      return (fields: fields, error: null);
    } on FormatException {
      return (fields: const <String, String>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON body'));
    } on TypeError {
      return (fields: const <String, String>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON structure'));
    }
  }
  return (
    fields: const <String, String>{},
    error: errorResponse(415, 'UNSUPPORTED_MEDIA_TYPE', 'Unsupported content type'),
  );
}

Future<({String? value, Response? error})> parseOptionalBodyField(Request request, String field) async {
  if ((request.contentLength ?? 0) == 0 && request.headers['content-type'] == null) {
    return (value: null, error: null);
  }

  final parsed = await parseBodyField(request, field);
  if (parsed.error != null) return parsed;
  return (value: trimmedOrNull(parsed.value), error: null);
}

Future<({Map<String, dynamic> json, Response? error})> parseJsonObjectBody(
  Request request, {
  required int maxBytes,
}) async {
  final ct = request.headers['content-type'] ?? '';
  if (!ct.startsWith('application/json')) {
    return (
      json: const <String, dynamic>{},
      error: errorResponse(415, 'UNSUPPORTED_MEDIA_TYPE', 'Unsupported content type'),
    );
  }
  try {
    final bodyResult = await readRequestBody(request, maxBytes: maxBytes);
    if (bodyResult.error != null) return (json: const <String, dynamic>{}, error: bodyResult.error);
    final body = bodyResult.body!;
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      return (json: const <String, dynamic>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON structure'));
    }
    return (json: json, error: null);
  } on FormatException {
    return (json: const <String, dynamic>{}, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON body'));
  }
}

/// Filesystem root that file-type references are resolved against.
Future<String> referenceRoot(ProjectService? projects) async {
  if (projects == null) return Directory.current.path;
  return (await projects.defaultProject).localPath;
}
