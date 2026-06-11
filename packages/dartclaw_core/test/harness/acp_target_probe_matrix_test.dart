import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ACP target probe matrix', () {
    test('read blocking and permission', () {
      const validator = AcpTargetValidator();

      final denied = validator.readBlockingEvidence(
        denied: true,
        response: {'noAccess': true, 'reason': 'denied'},
        rawMethod: 'fs/read_text_file',
      );
      final leaked = validator.readBlockingEvidence(
        denied: true,
        response: {'noAccess': true, 'content': 'secret'},
        rawMethod: 'fs/read_text_file',
      );
      final wrongMethod = validator.readBlockingEvidence(
        denied: true,
        response: {'noAccess': true},
        rawMethod: 'file/read',
      );
      const permission = AcpTargetOperationEvidence(
        operation: AcpTargetOperation.sessionRequestPermission,
        status: AcpTargetEvidenceStatus.guardMediated,
        rawMethod: 'session/request_permission',
      );

      expect(denied.status.id, 'guard_mediated');
      expect(leaked.status.id, 'failed');
      expect(wrongMethod.status.id, 'failed');
      expect(permission.rawMethod, 'session/request_permission');
      expect(permission.status.id, 'guard_mediated');
    });
  });
}
