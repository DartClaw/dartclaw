import 'package:dartclaw_core/src/security/cloudflare_detector.dart';
import 'package:test/test.dart';

void main() {
  group('CloudflareDetector', () {
    test('detects "Just a moment" title', () {
      const html = '<html><head><title>Just a moment...</title></head></html>';
      expect(CloudflareDetector.isCloudflareChallenge(html), isTrue);
    });

    test('detects "Checking your browser"', () {
      const html = '<div>Checking your browser before accessing the site</div>';
      expect(CloudflareDetector.isCloudflareChallenge(html), isTrue);
    });

    test('detects cf-browser-verification', () {
      const html = '<div id="cf-browser-verification">Please wait</div>';
      expect(CloudflareDetector.isCloudflareChallenge(html), isTrue);
    });

    test('detects challenges.cloudflare.com', () {
      const html = '<script src="https://challenges.cloudflare.com/cdn-cgi/challenge"></script>';
      expect(CloudflareDetector.isCloudflareChallenge(html), isTrue);
    });

    test('detects __cf_chl_ token', () {
      const html = '<input name="__cf_chl_tk" value="abc123">';
      expect(CloudflareDetector.isCloudflareChallenge(html), isTrue);
    });

    test('case insensitive', () {
      const html = '<title>JUST A MOMENT...</title>';
      expect(CloudflareDetector.isCloudflareChallenge(html), isTrue);
    });

    test('normal HTML not detected', () {
      const html = '<html><body><h1>Hello World</h1><p>Normal content</p></body></html>';
      expect(CloudflareDetector.isCloudflareChallenge(html), isFalse);
    });

    test('empty content not detected', () {
      expect(CloudflareDetector.isCloudflareChallenge(''), isFalse);
    });
  });
}
