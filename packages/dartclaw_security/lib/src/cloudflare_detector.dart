/// Detects Cloudflare challenge pages in web-fetched content.
///
/// These pages are not prompt injection — they're CAPTCHA/JS challenges
/// that should be skipped (not blocked) by content-guard.
class CloudflareDetector {
  static const _indicators = [
    'just a moment',
    'checking your browser',
    'cf-browser-verification',
    'challenges.cloudflare.com',
    '__cf_chl_',
    'cf_chl_opt',
    'ray id:',
  ];

  const CloudflareDetector._();

  /// Returns true if [content] looks like a Cloudflare challenge page.
  static bool isCloudflareChallenge(String content) {
    final lower = content.toLowerCase();
    return _indicators.any(lower.contains);
  }
}
