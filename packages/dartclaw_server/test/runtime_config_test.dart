import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('RuntimeConfig', () {
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
  });
}
