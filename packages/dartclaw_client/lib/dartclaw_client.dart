/// Client for a running DartClaw server's HTTP API and SSE streams.
///
/// The package depends on nothing but `dart:io` — hold a base URI and a bearer
/// token and you can drive the server without the DartClaw runtime, a config
/// file, or a DartClaw data directory.
///
/// ```dart
/// final client = DartclawApiClient(
///   baseUri: Uri.parse('http://localhost:3333'),
///   token: 'your-gateway-token',
/// );
/// final tasks = await client.getList('/api/tasks');
/// await for (final event in client.streamEvents('/api/events')) {
///   print(event['type']);
/// }
/// ```
library;

export 'src/dartclaw_api_client.dart'
    show ApiRequest, ApiResponse, ApiTransport, DartclawApiClient, DartclawApiException;
