import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('RuntimeConfig', () {
    test('initializes with provided values', () {
      final rc = RuntimeConfig(
        heartbeatEnabled: true,
        gitSyncEnabled: false,
        gitSyncPushEnabled: true,
      );
      expect(rc.heartbeatEnabled, isTrue);
      expect(rc.gitSyncEnabled, isFalse);
      expect(rc.gitSyncPushEnabled, isTrue);
    });

    test('gitSyncPushEnabled defaults to true', () {
      final rc = RuntimeConfig(heartbeatEnabled: false, gitSyncEnabled: false);
      expect(rc.gitSyncPushEnabled, isTrue);
    });

    test('toJson returns correct structure', () {
      final rc = RuntimeConfig(
        heartbeatEnabled: true,
        gitSyncEnabled: true,
        gitSyncPushEnabled: false,
      );
      final json = rc.toJson();
      expect(json['heartbeat'], {'enabled': true});
      expect(json['gitSync'], {'enabled': true, 'pushEnabled': false});
    });

    test('state is mutable', () {
      final rc = RuntimeConfig(
        heartbeatEnabled: true,
        gitSyncEnabled: true,
      );
      rc.heartbeatEnabled = false;
      rc.gitSyncEnabled = false;
      rc.gitSyncPushEnabled = false;

      expect(rc.heartbeatEnabled, isFalse);
      expect(rc.gitSyncEnabled, isFalse);
      expect(rc.gitSyncPushEnabled, isFalse);
    });

    test('toggle is idempotent', () {
      final rc = RuntimeConfig(
        heartbeatEnabled: true,
        gitSyncEnabled: false,
      );

      // Set same value again
      rc.heartbeatEnabled = true;
      rc.gitSyncEnabled = false;

      expect(rc.heartbeatEnabled, isTrue);
      expect(rc.gitSyncEnabled, isFalse);
    });
  });
}
