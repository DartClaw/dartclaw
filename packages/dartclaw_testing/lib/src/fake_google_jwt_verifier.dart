import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:http/http.dart' as http;

typedef GoogleJwtVerifyCallback = Future<bool> Function(String? authHeader);

/// Recording [GoogleJwtVerifier] fake with configurable verification outcomes.
class FakeGoogleJwtVerifier extends GoogleJwtVerifier {
  FakeGoogleJwtVerifier({GoogleChatAudienceConfig? audience, this.shouldVerify = true, this.onVerify})
    : super(
        audience:
            audience ??
            const GoogleChatAudienceConfig(
              mode: GoogleChatAudienceMode.appUrl,
              value: 'https://example.com/integrations/googlechat',
            ),
        httpClient: _NoopHttpClient(),
      );

  bool shouldVerify;
  final GoogleJwtVerifyCallback? onVerify;

  int verifyCallCount = 0;
  final List<String?> verifiedAuthHeaders = [];

  @override
  Future<bool> verify(String? authHeader) async {
    verifyCallCount += 1;
    verifiedAuthHeaders.add(authHeader);
    final callback = onVerify;
    if (callback != null) {
      return callback(authHeader);
    }
    return shouldVerify;
  }
}

class _NoopHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnimplementedError('FakeGoogleJwtVerifier should not send HTTP requests.');
  }
}
