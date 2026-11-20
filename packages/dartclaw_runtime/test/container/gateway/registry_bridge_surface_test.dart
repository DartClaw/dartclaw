import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show RegistryRecord, RegistryUpstream;
import 'package:dartclaw_runtime/src/container/gateway/gateway_models.dart';
import 'package:dartclaw_runtime/src/container/gateway/host_gateway.dart';
import 'package:dartclaw_runtime/src/container/gateway/provider_adapter.dart';
import 'package:dartclaw_runtime/src/container/gateway/registry_bridge_surface.dart';
import 'package:test/test.dart';

import 'gateway_test_support.dart';

void main() {
  late HttpServer first;
  late HttpServer second;
  late HttpServer unpinned;
  late RegistryBridgeSurface surface;
  late Completer<void> finishRedirect;
  late List<String> hits;
  late List<({String authority, String ecosystem, String path, int status, bool served})> audit;
  late Map<String, List<String>> forwarded;

  setUp(() async {
    finishRedirect = Completer<void>();
    hits = [];
    audit = [];
    forwarded = {};
    first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unpinned = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unpinned.listen((request) async {
      hits.add('unpinned${request.uri}');
      request.response.write('must never be fetched');
      await request.response.close();
    });
    second.listen((request) async {
      hits.add('second${request.uri}');
      if (request.uri.path == '/b') request.response.statusCode = 404;
      request.response.write('redirected');
      await request.response.close();
    });
    first.listen((request) async {
      hits.add('first${request.uri}');
      request.headers.forEach((name, values) => forwarded[name] = values);
      switch (request.uri.path) {
        case '/same-origin':
          request.response.statusCode = 302;
          request.response.headers.set('location', '/archive');
        case '/inside':
          request.response.statusCode = 302;
          request.response.headers.set('location', 'http://127.0.0.1:${second.port}/archive');
        case '/streaming-redirect':
          request.response.statusCode = 302;
          request.response.headers.set('location', 'http://127.0.0.1:${second.port}/archive');
          request.response.write('discarded response body');
          await request.response.flush();
          await finishRedirect.future;
        case '/failure':
          final socket = await request.response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        case '/scheme':
          request.response.statusCode = 302;
          request.response.headers.set('location', 'file:///secret');
        case '/outside':
          request.response.statusCode = 302;
          request.response.headers.set('location', 'http://127.0.0.1:${unpinned.port}/stolen');
        case '/loop':
          request.response.statusCode = 302;
          request.response.headers.set('location', '/loop');
        case '/large':
          request.response.contentLength = 4097;
          request.response.add(List.filled(4097, 42));
        default:
          request.response.headers.set('set-cookie', 'host-secret');
          request.response.headers.set('authorization', 'host-secret');
          request.response.headers.set('x-api-key', 'host-secret');
          request.response.headers.set('x-visible', 'control');
          request.response.write('archive');
      }
      await request.response.close();
    });
    surface = RegistryBridgeSurface(
      records: [
        RegistryRecord(
          name: 'test-registry',
          upstreams: [
            RegistryUpstream(route: 'packages', origin: 'http://127.0.0.1:${first.port}'),
            RegistryUpstream(route: 'downloads', origin: 'http://127.0.0.1:${second.port}'),
          ],
        ),
      ],
      authorityId: 'authority-17',
      limits: const BridgeLimits(maxResponseBytes: 4096),
      onRequest: (authority, ecosystem, path, status, served) async =>
          audit.add((authority: authority, ecosystem: ecosystem, path: path, status: status, served: served)),
    );
  });
  tearDown(() async {
    finishRedirect.complete();
    await surface.dispose();
    await first.close(force: true);
    await second.close(force: true);
    await unpinned.close(force: true);
  });

  List<RegistryRecord> registryRecords() => [
    builtInRegistryOn('pub', {'pub': Uri.parse('http://127.0.0.1:${second.port}')}),
    builtInRegistryOn('npm', {'npm': Uri.parse('http://127.0.0.1:${first.port}')}),
  ];

  Future<GatewayResponse> fetch(String path, {String method = 'GET', Map<String, List<String>> headers = const {}}) =>
      surface.handle(
        GatewayRequest(
          principal: principal(),
          method: method,
          path: path,
          headers: headers,
          body: const Stream.empty(),
        ),
      );

  test('refuses a publish request without contacting the origin', () async {
    for (final method in ['POST', 'PUT', 'DELETE']) {
      await expectLater(
        fetch('/packages/api/packages/versions/new', method: method),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 405)),
      );
    }
    expect(hits, isEmpty);
    expect(await utf8.decodeStream((await fetch('/packages/archive')).body), 'archive');
    expect(await (await fetch('/packages/archive', method: 'HEAD')).body.toList(), isEmpty);
    expect(hits, hasLength(2));
  });

  test('follows redirects only inside the pinned origin set', () async {
    expect(await utf8.decodeStream((await fetch('/packages/inside')).body), 'redirected');
    expect(hits, ['first/inside', 'second/archive']);
    for (final path in ['/unknown/archive', '//other.example/x', '/packages/outside', '/packages/scheme']) {
      await expectLater(fetch(path), throwsA(isA<GatewayDenied>()));
    }
    expect(hits, ['first/inside', 'second/archive', 'first/outside', 'first/scheme']);
    await expectLater(
      fetch('/packages/loop'),
      throwsA(isA<GatewayDenied>().having((e) => e.reason, 'reason', contains('5 hops'))),
    );
    expect(hits.where((path) => path == 'first/loop'), hasLength(6));
    final escaped = await fetch('/packages/@scope%2fpkg?query=kept');
    await escaped.body.drain<void>();
    expect(hits.last.toLowerCase(), 'first/@scope%2fpkg?query=kept');
  });

  test('drops credential headers both ways', () async {
    final response = await fetch(
      '/packages/archive',
      headers: {
        'Authorization': ['container-secret'],
        'Cookie': ['container-secret'],
        'X-Api-Key': ['container-secret'],
        'Accept-Encoding': ['br'],
        'X-Control': ['control'],
        'Host': ['other.example'],
      },
    );
    await response.body.drain<void>();
    expect(forwarded.keys, isNot(contains('authorization')));
    expect(forwarded.keys, isNot(contains('cookie')));
    expect(forwarded.keys, isNot(contains('x-api-key')));
    expect(forwarded['accept-encoding'], isNot(contains('br')));
    expect(forwarded['host'], ['127.0.0.1:${first.port}']);
    expect(forwarded['x-control'], ['control']);
    expect(response.headers.keys, isNot(contains('set-cookie')));
    expect(response.headers.keys, isNot(contains('authorization')));
    expect(response.headers.keys, isNot(contains('x-api-key')));
    expect(response.headers['x-visible'], ['control']);
  });

  test('follows a pinned redirect without waiting for its unused body', () async {
    final response = await fetch('/packages/streaming-redirect').timeout(const Duration(seconds: 2));
    expect(await utf8.decodeStream(response.body), 'redirected');
    expect(hits, ['first/streaming-redirect', 'second/archive']);
  });

  test('refuses an advertised oversize artifact naming the cap', () async {
    await expectLater(
      fetch('/packages/large'),
      throwsA(
        isA<GatewayDenied>()
            .having((e) => e.status, 'status', 502)
            .having((e) => e.reason, 'reason', contains('4096 bytes')),
      ),
    );
  });

  test('an upstream connection failure is audited and refuses without upstream detail', () async {
    await expectLater(
      fetch('/packages/failure?secret=hidden'),
      throwsA(
        isA<GatewayDenied>().having((e) => e.reason, 'reason', 'registry test-registry: upstream request failed'),
      ),
    );
    expect(audit, [
      (
        authority: 'authority-17',
        ecosystem: 'test-registry',
        path: '/packages/failure?secret=hidden',
        status: 502,
        served: false,
      ),
    ]);
  });

  test('records each request with its query and keeps refusal reasons query-free', () async {
    for (final path in ['/packages/a?secret=kept', '/downloads/b']) {
      await (await fetch(path)).body.drain<void>();
    }
    await expectLater(
      fetch('/packages/publish?secret=hidden', method: 'POST'),
      throwsA(
        isA<GatewayDenied>().having(
          (e) => e.reason,
          'reason',
          allOf(contains('test-registry'), contains('GET and HEAD'), isNot(contains('hidden'))),
        ),
      ),
    );
    expect(audit, [
      (
        authority: 'authority-17',
        ecosystem: 'test-registry',
        path: '/packages/a?secret=kept',
        status: 200,
        served: true,
      ),
      (authority: 'authority-17', ecosystem: 'test-registry', path: '/downloads/b', status: 404, served: true),
      (
        authority: 'authority-17',
        ecosystem: 'test-registry',
        path: '/packages/publish?secret=hidden',
        status: 405,
        served: false,
      ),
    ]);

    // The same through a gateway pipe, where a refusal becomes a GuardBlockEvent reason.
    final pypi = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => pypi.close(force: true));
    pypi.listen((request) async {
      request.response.write('index');
      await request.response.close();
    });
    final denials = <String>[];
    final gatewayAudit = <({String authority, String ecosystem, String path, int status, bool served})>[];
    final gateway = HostGateway(
      providerAdapters: {
        'claude': AnthropicMessagesAdapter(credential: ProviderCredentialSource.apiKey(() => 'unused')),
      },
      registries: [
        builtInRegistryOn('pypi', {'pypi': Uri.parse('http://127.0.0.1:${pypi.port}')}),
      ],
      onRegistryRequest: (authority, ecosystem, path, status, served) async =>
          gatewayAudit.add((authority: authority, ecosystem: ecosystem, path: path, status: status, served: served)),
      onDenied: (_, reason) => denials.add(reason),
    );
    addTearDown(gateway.dispose);
    final channel = FakeBridgeChannel();
    final authority = gateway.register(principal: principal());
    gateway.attach(authority, BridgeSurface.registry, channel);
    await channel.handshake(BridgeSurface.registry);
    final served = await channel.request(1, method: 'GET', path: '/pypi/simple/pkg/?format=json');
    expect(served.status, 200);
    final refused = await channel.request(2, method: 'POST', path: '/pypi/simple/?secret=hidden');
    expect(refused.status, 405);
    expect(gatewayAudit, [
      (authority: authority.id, ecosystem: 'pypi', path: '/pypi/simple/pkg/?format=json', status: 200, served: true),
      (authority: authority.id, ecosystem: 'pypi', path: '/pypi/simple/?secret=hidden', status: 405, served: false),
    ]);
    expect(denials.single, allOf(contains('pypi'), contains('GET and HEAD'), isNot(contains('secret'))));
  });

  test('rewrites JSON only by the record rule and only to its own pins', () async {
    final files = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final index = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final downloads = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final simple = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    for (final server in [files, index, downloads, simple]) {
      addTearDown(() => server.close(force: true));
    }
    String at(HttpServer server) => 'http://127.0.0.1:${server.port}';
    final body = utf8.encode(
      jsonEncode({
        'files': [
          {'url': '${at(files)}/packages/ab/pkg-1.0.tar.gz?x=1'},
          {'url': '${at(files)}/packages/cd/pkg-1.0.whl#sha256=abc'},
        ],
        'index': '${at(simple)}/simple/',
        'other_record': '${at(downloads)}/crates/x',
        'unpinned': '${at(unpinned)}/stolen',
        'api': 'https://crates.io',
      }),
    );
    final config = utf8.encode(jsonEncode({'dl': '${at(downloads)}/crates', 'api': 'https://crates.io'}));
    const pypiJson = 'application/vnd.pypi.simple.v1+json';
    Future<void> serve(HttpRequest request, String type, List<int> bytes, {bool gzipped = false}) async {
      request.response.headers.set('content-type', type);
      if (gzipped) request.response.headers.set('content-encoding', 'gzip');
      request.response.add(gzipped ? gzip.encode(bytes) : bytes);
      await request.response.close();
    }

    simple.listen((request) async {
      switch (request.uri.path) {
        case '/simple/pkg':
          request.response.statusCode = 301;
          request.response.headers.set('location', '/simple/pkg/');
          await request.response.close();
        case '/simple/charset/':
          await serve(request, '$pypiJson; charset=utf-8', body);
        case '/simple/gzip/':
          await serve(request, pypiJson, body, gzipped: true);
        case '/simple/html/':
          await serve(request, 'text/html', body);
        default:
          await serve(request, pypiJson, body);
      }
    });
    files.listen((request) => serve(request, pypiJson, body));
    index.listen((request) => serve(request, 'application/octet-stream', config));
    await surface.dispose();
    surface = RegistryBridgeSurface(
      records: [
        builtInRegistryOn('pypi', {'pypi': Uri.parse(at(simple)), 'pypi-files': Uri.parse(at(files))}),
        builtInRegistryOn('crates', {'crates': Uri.parse(at(index)), 'crates-dl': Uri.parse(at(downloads))}),
      ],
      authorityId: 'authority-17',
    );
    Future<List<int>> bytesOf(String path) async => (await fetch(path)).body.expand((chunk) => chunk).toList();

    for (final path in ['/pypi/simple/pkg/', '/pypi/simple/charset/', '/pypi/simple/gzip/', '/pypi/simple/pkg']) {
      final rewritten = jsonDecode(utf8.decode(await bytesOf(path))) as Map<String, dynamic>;
      expect(rewritten, {
        'files': [
          {'url': 'http://127.0.0.1:8082/pypi-files/packages/ab/pkg-1.0.tar.gz?x=1'},
          {'url': 'http://127.0.0.1:8082/pypi-files/packages/cd/pkg-1.0.whl#sha256=abc'},
        ],
        'index': 'http://127.0.0.1:8082/pypi/simple/',
        'other_record': '${at(downloads)}/crates/x',
        'unpinned': '${at(unpinned)}/stolen',
        'api': 'https://crates.io',
      }, reason: path);
    }
    // Wrong media type, a path outside the rule's prefix, and a pin the rule does not name.
    for (final path in ['/pypi/simple/html/', '/pypi/pypi/pkg/json', '/pypi-files/simple/pkg/']) {
      expect(await bytesOf(path), body, reason: path);
    }
    expect(jsonDecode(utf8.decode(await bytesOf('/crates/config.json'))), {
      'dl': 'http://127.0.0.1:8082/crates-dl/crates',
      'api': 'https://crates.io',
    });
  });

  test('rewrites pinned pub download addresses and leaves archives untouched', () async {
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
    await surface.dispose();
    surface = RegistryBridgeSurface(
      records: [
        builtInRegistryOn('pub', {'pub': base}),
      ],
      authorityId: 'authority-test',
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

  test('serves npm packuments unmodified', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${origin.port}');
    final packument = utf8.encode(
      '{"dist":{"tarball":"https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz","other":"$base/archive"}}',
    );
    final types = ['application/json', 'application/vnd.npm.install-v1+json', 'application/octet-stream'];
    var served = 0;
    origin.listen((request) async {
      final encoded = request.uri.path == '/is-odd';
      request.response.headers.set('content-type', types[served++ % types.length]);
      if (encoded) request.response.headers.set('content-encoding', 'gzip');
      request.response.add(encoded ? gzip.encode(packument) : packument);
      await request.response.close();
    });
    await surface.dispose();
    surface = RegistryBridgeSurface(
      records: [
        builtInRegistryOn('npm', {'npm': base}),
      ],
      authorityId: 'authority-test',
    );
    for (final path in ['/npm/is-odd', '/npm/@scope%2Fpkg', '/npm/is-odd/-/is-odd-3.0.1.tgz']) {
      for (var i = 0; i < types.length; i++) {
        final response = await fetch(path);
        expect(response.status, 200);
        expect(await response.body.expand((chunk) => chunk).toList(), packument, reason: path);
      }
    }
  });

  group('pub and npm', () {
    setUp(() async {
      await surface.dispose();
      surface = RegistryBridgeSurface(
        records: registryRecords(),
        authorityId: 'authority-17',
        onRequest: (authority, ecosystem, path, status, served) async =>
            audit.add((authority: authority, ecosystem: ecosystem, path: path, status: status, served: served)),
      );
    });

    test('passes a scoped npm package path to the origin with its slash encoded', () async {
      for (final path in ['/npm/@sindresorhus%2fis', '/npm/@sindresorhus/is/-/is-4.6.0.tgz']) {
        final response = await fetch(path);
        expect(response.status, 200);
        await response.body.drain<void>();
      }

      expect(hits.map((hit) => hit.replaceAll('%2F', '%2f')), [
        'first/@sindresorhus%2fis',
        'first/@sindresorhus/is/-/is-4.6.0.tgz',
      ]);
    });

    test('applies the refusal rules to every enabled record', () async {
      final denials = <String>[];
      final gateway = HostGateway(
        providerAdapters: {
          'claude': AnthropicMessagesAdapter(credential: ProviderCredentialSource.apiKey(() => 'unused')),
        },
        registries: registryRecords(),
        onDenied: (_, reason) => denials.add(reason),
      );
      addTearDown(gateway.dispose);
      final channel = FakeBridgeChannel();
      gateway.attach(gateway.register(principal: principal()), BridgeSurface.registry, channel);
      await channel.handshake(BridgeSurface.registry);

      var requestId = 0;
      for (final route in ['npm', 'pub']) {
        for (final (method, path) in [('PUT', '/is-odd'), ('POST', '/-/npm/v1/security/advisories/bulk')]) {
          final refusal = await channel.request(++requestId, method: method, path: '/$route$path');
          expect(refusal.status, 405);
          expect(refusal.isDenied, isTrue);
        }
      }
      expect(hits, isEmpty);
      final refused = await channel.request(++requestId, method: 'GET', path: '/npm/inside');
      expect(refused.status, 403);
      expect(refused.isDenied, isTrue);
      expect(hits, ['first/inside']);
      final served = await channel.request(++requestId, method: 'GET', path: '/npm/same-origin');
      expect(served.status, 200);
      expect(served.body, 'archive');
      expect(hits, ['first/inside', 'first/same-origin', 'first/archive']);
      expect(denials, [
        'registry: registry npm: only GET and HEAD are allowed',
        'registry: registry npm: only GET and HEAD are allowed',
        'registry: registry pub: only GET and HEAD are allowed',
        'registry: registry pub: only GET and HEAD are allowed',
        'registry: registry npm: redirect origin is not pinned',
      ]);
    });

    test('keeps each route on its own origin', () async {
      expect(await utf8.decodeStream((await fetch('/pub/is-odd')).body), 'redirected');
      expect(await utf8.decodeStream((await fetch('/npm/is-odd')).body), 'archive');
      expect(hits, ['second/is-odd', 'first/is-odd']);
    });

    test('records served npm requests under the npm ecosystem', () async {
      for (final path in ['/npm/is-odd', '/npm/is-odd/-/is-odd-3.0.1.tgz']) {
        final response = await fetch(path);
        expect(response.status, 200);
        await response.body.drain<void>();
      }

      expect(audit, [
        (authority: 'authority-17', ecosystem: 'npm', path: '/npm/is-odd', status: 200, served: true),
        (
          authority: 'authority-17',
          ecosystem: 'npm',
          path: '/npm/is-odd/-/is-odd-3.0.1.tgz',
          status: 200,
          served: true,
        ),
      ]);
    });
  });
}
