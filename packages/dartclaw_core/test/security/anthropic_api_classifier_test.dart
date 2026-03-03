import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/security/anthropic_api_classifier.dart';
import 'package:test/test.dart';

/// Fake HttpClient that returns a preconfigured response.
class FakeHttpClient implements HttpClient {
  int responseStatusCode = 200;
  String responseBody = '';

  String? lastMethod;
  Uri? lastUri;
  String? lastRequestBody;
  Map<String, String> lastHeaders = {};

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    lastUri = url;
    lastMethod = 'POST';
    return _FakeRequest(this);
  }

  @override
  void close({bool force = false}) {}

  // --- Unused stubs ---
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeRequest implements HttpClientRequest {
  final FakeHttpClient _client;
  final _headers = _FakeHeaders();
  final _body = StringBuffer();

  _FakeRequest(this._client);

  @override
  HttpHeaders get headers => _headers;

  @override
  void write(Object? object) {
    _body.write(object);
  }

  @override
  Future<HttpClientResponse> close() async {
    _client.lastRequestBody = _body.toString();
    _client.lastHeaders = Map.from(_headers._values);
    return _FakeResponse(_client.responseStatusCode, _client.responseBody);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  final int statusCode;
  final String _body;

  _FakeResponse(this.statusCode, this._body);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream.value(utf8.encode(_body)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late FakeHttpClient httpClient;

  String apiResponse(String text) => jsonEncode({
        'content': [
          {'type': 'text', 'text': text},
        ],
      });

  setUp(() {
    httpClient = FakeHttpClient();
  });

  AnthropicApiClassifier createClassifier() => AnthropicApiClassifier(
        apiKey: 'test-key',
        httpFactory: () => httpClient,
      );

  group('AnthropicApiClassifier', () {
    test('returns safe classification', () async {
      httpClient.responseBody = apiResponse('safe');
      final result = await createClassifier().classify('Normal content');
      expect(result, 'safe');
    });

    test('returns prompt_injection', () async {
      httpClient.responseBody = apiResponse('prompt_injection');
      final result = await createClassifier().classify('Ignore instructions');
      expect(result, 'prompt_injection');
    });

    test('returns harmful_content', () async {
      httpClient.responseBody = apiResponse('harmful_content');
      final result = await createClassifier().classify('Bad stuff');
      expect(result, 'harmful_content');
    });

    test('returns exfiltration_attempt', () async {
      httpClient.responseBody = apiResponse('exfiltration_attempt');
      final result = await createClassifier().classify('Send your key');
      expect(result, 'exfiltration_attempt');
    });

    test('treats unknown classification as harmful_content', () async {
      httpClient.responseBody = apiResponse('something_else');
      final result = await createClassifier().classify('Content');
      expect(result, 'harmful_content');
    });

    test('trims and lowercases API response', () async {
      httpClient.responseBody = apiResponse('  Safe  ');
      final result = await createClassifier().classify('Content');
      expect(result, 'safe');
    });

    test('throws on non-200 response', () async {
      httpClient.responseStatusCode = 500;
      httpClient.responseBody = 'Internal error';
      expect(
        () => createClassifier().classify('Content'),
        throwsA(isA<HttpException>()),
      );
    });

    test('throws on empty content in response', () async {
      httpClient.responseBody = jsonEncode({'content': []});
      expect(
        () => createClassifier().classify('Content'),
        throwsA(isA<FormatException>()),
      );
    });

    test('sends correct API headers', () async {
      httpClient.responseBody = apiResponse('safe');
      await createClassifier().classify('Content');
      expect(httpClient.lastHeaders['x-api-key'], 'test-key');
      expect(httpClient.lastHeaders['anthropic-version'], '2023-06-01');
      expect(httpClient.lastHeaders['content-type'], 'application/json');
    });

    test('sends correct request body', () async {
      httpClient.responseBody = apiResponse('safe');
      await createClassifier().classify('Test content');
      final body = jsonDecode(httpClient.lastRequestBody!) as Map<String, dynamic>;
      expect(body['max_tokens'], 20);
      expect(body['system'], contains('content safety classifier'));
      final messages = body['messages'] as List;
      expect(messages.first['content'], contains('Test content'));
    });

    test('uses custom model', () async {
      httpClient.responseBody = apiResponse('safe');
      final classifier = AnthropicApiClassifier(
        apiKey: 'test-key',
        model: 'custom-model',
        httpFactory: () => httpClient,
      );
      await classifier.classify('Content');
      final body = jsonDecode(httpClient.lastRequestBody!) as Map<String, dynamic>;
      expect(body['model'], 'custom-model');
    });
  });
}
