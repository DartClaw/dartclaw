import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('SessionStore', () {
    late SessionStore store;

    setUp(() {
      store = SessionStore();
    });

    test('createSession returns 64-char hex string', () {
      final id = store.createSession();
      expect(id.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(id), isTrue);
    });

    test('validate returns true for fresh session', () {
      final id = store.createSession();
      expect(store.validate(id), isTrue);
    });

    test('validate returns false for unknown session', () {
      expect(store.validate('nonexistent'), isFalse);
    });

    test('validate returns false and evicts expired session', () {
      final store = SessionStore(ttl: Duration.zero);
      final id = store.createSession();
      // Session should be expired immediately
      expect(store.validate(id), isFalse);
      expect(store.length, 0);
    });

    test('invalidateAll clears all sessions', () {
      store.createSession();
      store.createSession();
      expect(store.length, 2);
      store.invalidateAll();
      expect(store.length, 0);
    });

    test('unique session IDs', () {
      final a = store.createSession();
      final b = store.createSession();
      expect(a, isNot(b));
    });
  });
}
