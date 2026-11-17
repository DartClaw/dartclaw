import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/src/container/gateway/pub_registry_adapter.dart';
import 'package:dartclaw_runtime/src/container/gateway/registry_bridge_surface.dart';
import 'package:dartclaw_runtime/src/container/gateway/gateway_models.dart';
import 'package:test/test.dart';

import 'gateway_test_support.dart';

void main() {
  test('client environment points PUB_HOSTED_URL at the pub route', () {
    expect(PubRegistryAdapter().clientEnvironment(Uri.parse('http://127.0.0.1:8082')), {
      'PUB_HOSTED_URL': 'http://127.0.0.1:8082/pub',
    });
  });

  test('rewrites pinned download addresses and leaves archives untouched', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${origin.port}');
    final archive = [0, 255, 7, 12, 99];
    final releaseArchive = Completer<void>();
    addTearDown(() {
      if (!releaseArchive.isCompleted) releaseArchive.complete();
    });
    origin.listen((request) async {
      if (request.uri.path.startsWith('/api/packages/')) {
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(
          gzip.encode(
            utf8.encode(
              jsonEncode({
                'archive_url': '$base/api/archives/example.tar.gz',
                'outside': 'https://other.example/archive',
                'lookalike': '${base}evil/archive',
              }),
            ),
          ),
        );
      } else {
        request.response.add(archive);
        await request.response.flush();
        await releaseArchive.future;
      }
      await request.response.close();
    });
    final surface = RegistryBridgeSurface(
      adapters: [PubRegistryAdapter(upstream: base)],
      authorityId: 'authority-test',
    );
    addTearDown(surface.dispose);
    Future<GatewayResponse> fetch(String path, {String method = 'GET'}) => surface.handle(
      GatewayRequest(principal: principal(), method: method, path: path, headers: const {}, body: const Stream.empty()),
    );
    final response = await fetch('/pub/api/packages/example');
    final metadata = jsonDecode(await utf8.decodeStream(response.body)) as Map<String, dynamic>;
    expect(metadata['archive_url'], 'http://127.0.0.1:8082/pub/api/archives/example.tar.gz');
    expect(metadata['outside'], 'https://other.example/archive');
    expect(metadata['lookalike'], '${base}evil/archive');
    expect(response.headers, isNot(contains('content-encoding')));
    expect(await (await fetch('/pub/api/packages/example', method: 'HEAD')).body.toList(), isEmpty);
    final artifact = await fetch('/pub/api/archives/example.tar.gz');
    releaseArchive.complete();
    expect(await artifact.body.expand((bytes) => bytes).toList(), archive);
  });
}
