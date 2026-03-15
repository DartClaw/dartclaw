import 'package:dartclaw_security/src/cloudflare_detector.dart';
import 'package:test/test.dart';

void main() {
  group('CloudflareDetector', () {
    test('detects Cloudflare challenge pages', () {
      // Representative positive cases — all different detection signals
      expect(CloudflareDetector.isCloudflareChallenge('<title>Just a moment...</title>'), isTrue);
      expect(
        CloudflareDetector.isCloudflareChallenge(
          '<script src="https://challenges.cloudflare.com/cdn-cgi/challenge"></script>',
        ),
        isTrue,
      );
      expect(CloudflareDetector.isCloudflareChallenge('<input name="__cf_chl_tk" value="abc123">'), isTrue);
      // Case insensitive
      expect(CloudflareDetector.isCloudflareChallenge('<title>JUST A MOMENT...</title>'), isTrue);
    });

    test('normal HTML and empty content are not detected', () {
      expect(
        CloudflareDetector.isCloudflareChallenge(
          '<html><body><h1>Hello World</h1><p>Normal content</p></body></html>',
        ),
        isFalse,
      );
      expect(CloudflareDetector.isCloudflareChallenge(''), isFalse);
    });
  });
}
