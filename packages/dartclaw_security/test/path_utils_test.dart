import 'package:dartclaw_security/src/path_utils.dart';
import 'package:test/test.dart';

void main() {
  group('expandHome', () {
    test('expands ~/foo when HOME is set', () {
      final result = expandHome('~/foo', env: {'HOME': '/home/user'});
      expect(result, equals('/home/user/foo'));
    });

    test('returns path unchanged when HOME is absent', () {
      final result = expandHome('~/foo', env: {});
      expect(result, equals('~/foo'));
    });

    test('expands bare ~ to HOME value', () {
      final result = expandHome('~', env: {'HOME': '/home/user'});
      expect(result, equals('/home/user'));
    });

    test('expands ~/ prefix (trailing slash only) to HOME', () {
      final result = expandHome('~/', env: {'HOME': '/home/user'});
      expect(result, equals('/home/user'));
    });

    test('leaves non-tilde paths unchanged', () {
      final result = expandHome('/absolute/path', env: {'HOME': '/home/user'});
      expect(result, equals('/absolute/path'));
    });

    test('leaves relative paths unchanged', () {
      final result = expandHome('relative/path', env: {'HOME': '/home/user'});
      expect(result, equals('relative/path'));
    });
  });
}
