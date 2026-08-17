import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    final bodyResult = await readRequestBody(request, maxBytes: maxSendBodyBytes);
    if (bodyResult.error != null) return (fields: const <String, String>{}, error: bodyResult.error);
    final body = bodyResult.body!;
    final params = Uri.splitQueryString(body);
    return (fields: params, error: null);
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

Future<({Map<String, dynamic> json, Response? error})> parseJsonObjectBody(Request request, {int? maxBytes}) async {
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

Future<({String? body, Response? error})> readRequestBody(Request request, {int? maxBytes}) async {
  final contentLength = request.contentLength;
  if (maxBytes != null && contentLength != null && contentLength > maxBytes) {
    return (body: null, error: errorResponse(413, 'REQUEST_TOO_LARGE', 'request body is too large'));
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    if (maxBytes != null && bytes.length + chunk.length > maxBytes) {
      return (body: null, error: errorResponse(413, 'REQUEST_TOO_LARGE', 'request body is too large'));
    }
    bytes.add(chunk);
  }
  try {
    return (body: utf8.decode(bytes.takeBytes()), error: null);
  } on FormatException {
    return (body: null, error: errorResponse(400, 'INVALID_INPUT', 'request body must be valid UTF-8'));
  }
}

/// Filesystem root that file-type references are resolved against.
Future<String> referenceRoot(ProjectService? projects) async {
  if (projects == null) return Directory.current.path;
  return (await projects.defaultProject).localPath;
}
