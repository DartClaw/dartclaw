import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

final class FakeAcpProcess extends CapturingFakeProcess {
  FakeAcpProcess({super.completeExitOnKill = true});

  Future<Map<String, dynamic>> waitForRequest(String method) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      for (final message in capturedStdinJson.reversed) {
        if (message['method'] == method) {
          return message;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for ACP request $method. Sent: $capturedStdinJson');
  }

  Future<void> respondTo(String method, Map<String, dynamic> result) async {
    final request = await waitForRequest(method);
    emitLine({'jsonrpc': '2.0', 'id': request['id'], 'result': result});
  }

  Future<void> failRequest(String method, String message) async {
    final request = await waitForRequest(method);
    emitLine({
      'jsonrpc': '2.0',
      'id': request['id'],
      'error': {'code': -32000, 'message': message},
    });
  }

  void emitLine(Map<String, dynamic> message) {
    emitStdout(jsonEncode(message));
  }

  void sendHostRequest(int id, String method, Map<String, dynamic> params) {
    emitLine({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
  }

  Future<Map<String, dynamic>> waitForResponse(int id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      for (final message in capturedStdinJson.reversed) {
        if (message['id'] == id) {
          return message;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for ACP response $id. Sent: ${jsonEncode(capturedStdinJson)}');
  }
}

Iterable<AcpTargetOperationEvidence> guardMediatedTargetEvidence() {
  return [
    for (final operation in AcpTargetOperation.values)
      AcpTargetOperationEvidence(
        operation: operation,
        status: AcpTargetEvidenceStatus.guardMediated,
        rawMethod: operation.rawMethod,
      ),
  ];
}
