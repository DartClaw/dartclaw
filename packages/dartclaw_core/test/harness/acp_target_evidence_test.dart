import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ACP target evidence', () {
    test('records every operation and classification with raw methods', () {
      for (final operation in AcpTargetOperation.values) {
        for (final status in AcpTargetEvidenceStatus.values) {
          final evidence = AcpTargetOperationEvidence(
            operation: operation,
            status: status,
            rawMethod: operation.rawMethod,
          );

          expect(evidence.toJson()['operation'], operation.id);
          expect(evidence.toJson()['status'], status.id);
        }
      }

      final result = AcpTargetValidationResult.guardMediated('goose');

      expect(result.evidence.keys.map((operation) => operation.id), [
        'prompt_response',
        'file_read',
        'file_write',
        'terminal_create',
        'session_request_permission',
        'read_blocking',
      ]);
      expect(result.evidence[AcpTargetOperation.fileRead]!.rawMethod, 'fs/read_text_file');
      expect(result.evidence[AcpTargetOperation.fileWrite]!.rawMethod, 'fs/write_text_file');
      expect(result.evidence[AcpTargetOperation.terminalCreate]!.rawMethod, 'terminal/create');
      expect(result.evidence[AcpTargetOperation.sessionRequestPermission]!.rawMethod, 'session/request_permission');
    });
  });
}
