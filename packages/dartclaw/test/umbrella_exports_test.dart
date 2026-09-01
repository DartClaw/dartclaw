import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw/dartclaw.dart';
import 'package:test/test.dart';

const _runtimePackages = [
  'dartclaw_core',
  'dartclaw_runtime',
  'dartclaw_workflow',
  'dartclaw_bridge',
  'dartclaw_whatsapp',
  'dartclaw_signal',
  'dartclaw_google_chat',
];

void main() {
  group('dartclaw umbrella exports', () {
    test('the API client and its transport seam resolve from the umbrella alone', () {
      final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), token: 'gateway-token');
      final request = ApiRequest(method: 'GET', uri: Uri.parse('http://localhost:3333/api/tasks'), headers: const {});
      final response = ApiResponse(statusCode: 204, headers: const {}, body: const Stream.empty());

      expect(client.baseUri.port, 3333);
      expect(client.token, 'gateway-token');
      expect(request.method, 'GET');
      expect(response.statusCode, 204);
      expect(ApiTransport, isNotNull);
      expect(const DartclawApiException('boom', code: 'AUTH_REQUIRED', statusCode: 401).statusCode, 401);
    });

    test('the shared DTO types the endpoints carry resolve from the umbrella alone', () {
      final session = Session(id: 'session-1', createdAt: DateTime.now(), updatedAt: DateTime.now());
      final message = Message(
        cursor: 0,
        id: 'm1',
        sessionId: 'session-1',
        role: 'user',
        content: 'hello',
        createdAt: DateTime.now(),
      );

      expect(session.type, SessionType.user);
      expect(message.role, 'user');
      expect(ChannelType.whatsapp.name, 'whatsapp');
    });

    // Absence cannot be asserted against an import, so it is asserted against
    // this package's own export graph. The transitive half — a re-exported
    // barrel growing a runtime edge — is the tier order in
    // `dev/package_tiers.txt`, which puts `dartclaw_client` one step above the
    // kernel so the kernel is the only workspace package it can reach.
    test('no harness, guard, storage, or channel package is in the export graph', () async {
      final barrelUri = (await Isolate.resolvePackageUri(Uri.parse('package:dartclaw/dartclaw.dart')))!;
      final barrelFile = File.fromUri(barrelUri);
      final packageRoot = barrelFile.parent.parent;
      final declaredDependencies = File('${packageRoot.path}/pubspec.yaml')
          .readAsStringSync()
          .split('dev_dependencies:')
          .first;
      final barrelSource = barrelFile.readAsStringSync();
      final exportLines = RegExp(r"^export '.*", multiLine: true).allMatches(barrelSource);

      for (final package in _runtimePackages) {
        expect(declaredDependencies, isNot(contains(package)), reason: '$package must not be an umbrella dependency');
        for (final line in exportLines) {
          expect(line[0], isNot(contains(package)), reason: '$package must not be re-exported by the umbrella');
        }
      }

      expect(exportLines.length, 2);
      expect(barrelSource, contains("export 'package:dartclaw_client/dartclaw_client.dart';"));
      expect(barrelSource, contains("export 'package:dartclaw_kernel/dartclaw_kernel.dart'"));
      expect(barrelSource, contains('show\n        Session,'));
      expect(barrelSource, isNot(contains('DartclawConfig')));
      expect(barrelSource, isNot(contains('GuardChain')));
    });
  });
}
