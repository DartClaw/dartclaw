import 'package:dartclaw_core/dartclaw_core.dart';

typedef GoogleJwtVerifyCallback = Future<bool> Function(String? authHeader);

/// Recording [GoogleJwtVerifier] fake with configurable verification outcomes.
class FakeGoogleJwtVerifier implements GoogleJwtVerifier {
  FakeGoogleJwtVerifier({this.shouldVerify = true, this.onVerify});

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

  @override
  void invalidateCache() {}
}
