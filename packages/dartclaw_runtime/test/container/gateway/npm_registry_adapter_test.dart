import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/src/container/gateway/gateway_models.dart';
import 'package:dartclaw_runtime/src/container/gateway/npm_registry_adapter.dart';
import 'package:dartclaw_runtime/src/container/gateway/registry_bridge_surface.dart';
import 'package:test/test.dart';

import 'gateway_test_support.dart';

void main() {
  test('client environment points npm_config_registry at the npm route and disables audit', () {
    final adapter = NpmRegistryAdapter();
    expect(adapter.ecosystem, 'npm');
    expect(adapter.origins, [(origin: Uri.https('registry.npmjs.org'), route: 'npm')]);
    expect(adapter.clientEnvironment(Uri.parse('http://127.0.0.1:8082')), {
      'npm_config_registry': 'http://127.0.0.1:8082/npm',
      'npm_config_audit': 'false',
    });
  });

  test('serves packuments unmodified', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${origin.port}');
    final packument = utf8.encode(
      '{"dist":{"tarball":"https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz","other":"$base/archive"}}',
    );
    final compressed = gzip.encode(packument);
    origin.listen((request) async {
      final encoded = request.uri.path == '/is-odd';
      request.response.headers.contentType = ContentType.json;
      if (encoded) request.response.headers.set('content-encoding', 'gzip');
      request.response.add(encoded ? compressed : packument);
      await request.response.close();
    });
    final adapter = NpmRegistryAdapter(upstream: base);
    final surface = RegistryBridgeSurface(adapters: [adapter], authorityId: 'authority-test');
    addTearDown(surface.dispose);

    for (final path in ['/is-odd', '/@scope%2Fpkg', '/is-odd/-/is-odd-3.0.1.tgz']) {
      for (final type in [
        null,
        'application/json',
        'application/vnd.npm.install-v1+json',
        'application/octet-stream',
      ]) {
        expect(adapter.carriesMetadata(path, type), isFalse, reason: '$path with $type');
      }
    }
    for (final path in ['/npm/is-odd', '/npm/@scope%2Fpkg']) {
      final response = await surface.handle(
        GatewayRequest(
          principal: principal(),
          method: 'GET',
          path: path,
          headers: const {},
          body: const Stream.empty(),
        ),
      );
      expect(response.status, 200);
      expect(await response.body.expand((chunk) => chunk).toList(), packument);
    }
  });
}
