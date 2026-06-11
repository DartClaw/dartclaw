import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Small handler client for API route tests.
///
/// Keeps route tests focused on the endpoint contract: method, path, expected
/// status, and decoded response body.
final class ApiRouteTestClient {
  ApiRouteTestClient(this.handler);

  final Handler handler;

  Future<Response> request(
    String method,
    String path, {
    Object? json,
    String? body,
    Map<String, String> headers = const {},
  }) async {
    final requestHeaders = <String, String>{if (json != null) 'content-type': 'application/json', ...headers};
    return await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        body: json == null ? body : jsonEncode(json),
        headers: requestHeaders,
      ),
    );
  }

  Future<Response> expectResponse(
    String method,
    String path, {
    Object? json,
    String? body,
    Map<String, String> headers = const {},
    required int status,
  }) async {
    final response = await request(method, path, json: json, body: body, headers: headers);
    expect(response.statusCode, status);
    return response;
  }

  Future<Map<String, dynamic>> expectJsonObject(
    String method,
    String path, {
    Object? json,
    String? body,
    Map<String, String> headers = const {},
    int status = 200,
  }) async {
    final response = await expectResponse(method, path, json: json, body: body, headers: headers, status: status);
    return decodeObject(await response.readAsString());
  }

  Future<List<dynamic>> expectJsonList(
    String method,
    String path, {
    Object? json,
    String? body,
    Map<String, String> headers = const {},
    int status = 200,
  }) async {
    final response = await expectResponse(method, path, json: json, body: body, headers: headers, status: status);
    return decodeList(await response.readAsString());
  }

  Future<String> expectText(
    String method,
    String path, {
    Object? json,
    String? body,
    Map<String, String> headers = const {},
    int status = 200,
  }) async {
    final response = await expectResponse(method, path, json: json, body: body, headers: headers, status: status);
    return response.readAsString();
  }

  Future<String> expectJsonErrorCode(
    String method,
    String path, {
    Object? json,
    String? body,
    Map<String, String> headers = const {},
    required int status,
  }) async {
    final response = await expectResponse(method, path, json: json, body: body, headers: headers, status: status);
    return errorCode(response);
  }
}

/// Extracts the `error.code` field from a JSON error response.
Future<String> errorCode(Response res) async {
  final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  return (body['error'] as Map<String, dynamic>)['code'] as String;
}

/// Decodes a JSON string as a [Map].
Map<String, dynamic> decodeObject(String body) {
  return jsonDecode(body) as Map<String, dynamic>;
}

/// Decodes a JSON string as a [List].
List<dynamic> decodeList(String body) {
  return jsonDecode(body) as List<dynamic>;
}

/// Creates a [Request] with a JSON body and content-type header.
Request jsonRequest(String method, String path, [Map<String, dynamic>? body]) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}

Request apiRequest(
  String method,
  String path, {
  Object? body,
  Object? jsonBody,
  Map<String, String> headers = const {},
}) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: jsonBody == null ? body : jsonEncode(jsonBody),
    headers: {if (jsonBody != null) 'content-type': 'application/json', ...headers},
  );
}

Future<Map<String, dynamic>> uploadSessionAttachment(
  Handler handler,
  String sessionId, {
  String filename = 'notes.md',
  String mediaType = 'text/markdown',
  String content = 'attached content',
}) async {
  final res = await handler(
    apiRequest(
      'POST',
      '/api/sessions/$sessionId/attachments',
      jsonBody: {
        'filename': filename,
        'mediaType': mediaType,
        'size': utf8.encode(content).length,
        'contentBase64': base64Encode(utf8.encode(content)),
      },
    ),
  );
  expect(res.statusCode, equals(201));
  return jsonDecode(await res.readAsString()) as Map<String, dynamic>;
}
