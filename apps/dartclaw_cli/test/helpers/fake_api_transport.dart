import 'dart:collection';
import 'dart:convert';

import 'package:dartclaw_cli/src/dartclaw_api_client.dart';

class FakeApiTransport implements ApiTransport {
  final Queue<ApiResponse> _sendResponses;
  final Queue<ApiResponse> _streamResponses;
  final List<ApiRequest> requests = <ApiRequest>[];

  FakeApiTransport({List<ApiResponse> sendResponses = const [], List<ApiResponse> streamResponses = const []})
    : _sendResponses = Queue<ApiResponse>.of(sendResponses),
      _streamResponses = Queue<ApiResponse>.of(streamResponses);

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    requests.add(request);
    return _sendResponses.removeFirst();
  }

  @override
  Future<ApiResponse> openStream(ApiRequest request) async {
    requests.add(request);
    return _streamResponses.removeFirst();
  }
}

ApiResponse jsonResponse(int statusCode, Object body) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: Stream.value(utf8.encode(jsonEncode(body))),
  );
}
