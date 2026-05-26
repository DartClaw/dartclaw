import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeGitRefOperand', () {
    test('accepts common branch and ref forms', () {
      expect(normalizeGitRefOperand(' main '), 'main');
      expect(normalizeGitRefOperand('release/0.16'), 'release/0.16');
      expect(normalizeGitRefOperand('origin/feature/local'), 'origin/feature/local');
      expect(normalizeGitRefOperand('refs/heads/feature_a-1'), 'refs/heads/feature_a-1');
    });

    test('rejects option-shaped and malformed refs', () {
      for (final ref in [
        '--upload-pack=/tmp/pwn',
        'origin/--help',
        'feature//double',
        'feature/../main',
        'feature name',
        'feature.lock',
        '@{upstream}',
      ]) {
        expect(() => normalizeGitRefOperand(ref), throwsFormatException, reason: ref);
      }
    });
  });
}
