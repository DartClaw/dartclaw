import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('records headers and returns the configured result', () async {
    final verifier = FakeGoogleJwtVerifier(shouldVerify: false);

    expect(await verifier.verify('Bearer invalid'), isFalse);
    expect(verifier.verifyCallCount, 1);
    expect(verifier.verifiedAuthHeaders, ['Bearer invalid']);
  });

  test('delegates verification to the callback', () async {
    final verifier = FakeGoogleJwtVerifier(onVerify: (header) async => header == 'Bearer valid');

    expect(await verifier.verify('Bearer valid'), isTrue);
    expect(await verifier.verify(null), isFalse);
    expect(verifier.verifyCallCount, 2);
    expect(verifier.verifiedAuthHeaders, ['Bearer valid', null]);
  });
}
