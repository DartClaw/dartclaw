import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class RecordingHttpClient implements HttpClient {
  new({
    this.statusCode = 200,
    String body = '',
    List<List<int>>? chunks,
    List<RecordingHttpResponseSpec> responses = const [],
    this.openError,
    this.closeError,
  }) : responseChunks = chunks ?? [utf8.encode(body)],
       responseSpecs = List.of(responses);

  int statusCode;
  List<List<int>> responseChunks;
  Object? openError;
  Object? closeError;
  Stream<List<int>>? responseStream;
  final List<RecordingHttpResponseSpec> responseSpecs;
  Duration? observedConnectionTimeout;
  bool forceClosed = false;
  final List<String> events = [];
  final List<RecordingHttpRequest> requests = [];

  @override
  Duration? get connectionTimeout => observedConnectionTimeout;

  @override
  set connectionTimeout(Duration? value) => observedConnectionTimeout = value;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    events.add('open');
    if (openError case final error?) throw error;
    final request = RecordingHttpRequest(this, method, url);
    requests.add(request);
    return request;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  void close({bool force = false}) {
    forceClosed = force;
  }

  RecordingHttpResponse response() {
    if (responseSpecs.isNotEmpty) {
      final spec = responseSpecs.removeAt(0);
      return RecordingHttpResponse(spec.statusCode, spec.stream ?? Stream.fromIterable(spec.chunks), spec.location);
    }
    return RecordingHttpResponse(statusCode, responseStream ?? Stream.fromIterable(responseChunks));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

final class RecordingHttpRequest implements HttpClientRequest {
  new(this.client, this.method, this.uri);

  final RecordingHttpClient client;
  @override
  final String method;
  @override
  final Uri uri;
  final RecordingHttpHeaders recordedHeaders = RecordingHttpHeaders();
  final List<int> bodyBytes = [];

  @override
  bool followRedirects = true;

  @override
  HttpHeaders get headers => recordedHeaders;

  @override
  void add(List<int> data) => bodyBytes.addAll(data);

  @override
  Future<HttpClientResponse> close() async {
    client.events.add('close');
    if (client.closeError case final error?) throw error;
    return client.response();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

final class RecordingHttpHeaders implements HttpHeaders {
  final Map<String, String> values = {};
  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) {
    _contentType = value;
    if (value != null) values[HttpHeaders.contentTypeHeader] = value.toString();
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

final class RecordingHttpResponse extends Stream<List<int>> implements HttpClientResponse {
  new(this.statusCode, this._stream, [String? location]) {
    if (location != null) headers.set(HttpHeaders.locationHeader, location);
  }

  @override
  final int statusCode;
  final Stream<List<int>> _stream;

  @override
  final RecordingHttpHeaders headers = RecordingHttpHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

final class RecordingHttpResponseSpec {
  const new({required this.statusCode, this.chunks = const [], this.stream, this.location});

  final int statusCode;
  final List<List<int>> chunks;
  final Stream<List<int>>? stream;
  final String? location;
}
