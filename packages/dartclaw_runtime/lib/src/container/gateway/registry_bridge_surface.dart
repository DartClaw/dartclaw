import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show RegistryRecord, RegistryUpstream;

import 'bridge_headers.dart';
import 'gateway_models.dart';

/// The routed outcome of one registry request; [path] includes its query.
typedef RegistryAuditSink = Future<void> Function(
  String authorityId,
  String ecosystem,
  String path,
  int status,
  bool served,
);

final class RegistryBridgeSurface implements GatewaySurfaceHandler {
  new({
    required List<RegistryRecord> records,
    required this.authorityId,
    this.limits = BridgeLimits.defaults,
    this.onRequest,
    HttpClient? client,
  }) : _records = List.unmodifiable(records),
       _client = client ?? HttpClient();

  /// Enabled records, validated by the config parser; never re-validated here.
  final List<RegistryRecord> _records;
  final String authorityId;
  final BridgeLimits limits;
  final RegistryAuditSink? onRequest;
  final HttpClient _client;

  static final Uri mirrorBase = Uri.parse('http://127.0.0.1:$registryBridgePort');

  @override
  BridgeSurface get surface => BridgeSurface.registry;

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    final separator = request.path.indexOf('?');
    final path = separator < 0 ? request.path : request.path.substring(0, separator);
    final query = separator < 0 ? null : request.path.substring(separator + 1);
    final route = _route(path);
    final ecosystem = route?.record.name ?? 'unknown';
    var status = 502;
    var served = false;
    try {
      if (route == null) {
        throw const GatewayDenied(status: 404, reason: 'registry unknown: path has no pinned ecosystem route');
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        throw GatewayDenied(status: 405, reason: 'registry $ecosystem: only GET and HEAD are allowed');
      }
      final upstreamPath = path.substring(route.pin.route.length + 1);
      var target = Uri.parse(route.pin.origin).replace(path: upstreamPath.isEmpty ? '/' : upstreamPath, query: query);
      var answering = route.pin;
      HttpClientResponse response;
      for (var redirects = 0; ; redirects++) {
        final outbound = await _client.openUrl(request.method, target);
        outbound.followRedirects = false;
        for (final entry in request.headers.entries) {
          if (droppedRequestHeaders.contains(entry.key.toLowerCase())) continue;
          for (final value in entry.value) {
            outbound.headers.add(entry.key, value);
          }
        }
        response = await outbound.close();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (!response.isRedirect || location == null) break;
        // Redirect bodies are discarded without waiting for their EOF.
        await response.listen((_) {}).cancel();
        final redirect = target.resolve(location);
        final pin = _pinFor(route.record, redirect);
        if (pin == null) {
          throw GatewayDenied(status: 403, reason: 'registry $ecosystem: redirect origin is not pinned');
        }
        if (redirects == 5) {
          throw GatewayDenied(status: 502, reason: 'registry $ecosystem: redirect chain exceeds 5 hops');
        }
        target = redirect;
        answering = pin;
      }
      if (response.contentLength > limits.maxResponseBytes) {
        // Cancel instead of draining an artifact the pipe can never serve.
        await response.listen((_) {}).cancel();
        throw GatewayDenied(
          status: 502,
          reason: 'registry $ecosystem: response exceeds ${limits.maxResponseBytes} bytes',
        );
      }
      final headers = <String, List<String>>{};
      response.headers.forEach((name, values) {
        if (!droppedResponseHeaders.contains(name.toLowerCase())) headers[name] = values;
      });
      Stream<List<int>> body = response;
      if (request.method == 'HEAD') {
        await response.drain<void>();
        body = const Stream.empty();
      } else if (_rewrites(
        route.record,
        answering,
        target.path,
        response.headers.value(HttpHeaders.contentTypeHeader),
      )) {
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > limits.maxResponseBytes) {
            throw GatewayDenied(
              status: 502,
              reason: 'registry $ecosystem: response exceeds ${limits.maxResponseBytes} bytes',
            );
          }
          bytes.addAll(chunk);
        }
        final rewritten = utf8.encode(jsonEncode(_rewrite(jsonDecode(utf8.decode(bytes)), route.record)));
        if (rewritten.length > limits.maxResponseBytes) {
          throw GatewayDenied(
            status: 502,
            reason: 'registry $ecosystem: response exceeds ${limits.maxResponseBytes} bytes',
          );
        }
        body = Stream.value(rewritten);
      }
      status = response.statusCode;
      served = true;
      return GatewayResponse(status: response.statusCode, headers: headers, body: body);
    } on GatewayDenied catch (denied) {
      status = denied.status;
      rethrow;
    } catch (_) {
      throw GatewayDenied(status: 502, reason: 'registry $ecosystem: upstream request failed');
    } finally {
      await onRequest?.call(authorityId, ecosystem, request.path, status, served);
    }
  }

  ({RegistryRecord record, RegistryUpstream pin})? _route(String path) {
    for (final record in _records) {
      for (final pin in record.upstreams) {
        if (path == '/${pin.route}' || path.startsWith('/${pin.route}/')) return (record: record, pin: pin);
      }
    }
    return null;
  }

  RegistryUpstream? _pinFor(RegistryRecord record, Uri uri) {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https') || uri.userInfo.isNotEmpty) return null;
    for (final pin in record.upstreams) {
      if (Uri.parse(pin.origin).origin == uri.origin) return pin;
    }
    return null;
  }

  /// Whether a rule of [record] covers the response [pin] answered for [path].
  static bool _rewrites(RegistryRecord record, RegistryUpstream pin, String path, String? contentType) {
    if (contentType == null) return false;
    final type = contentType.split(';').first.trim().toLowerCase();
    return record.rewriteJson.any(
      (rule) =>
          rule.route == pin.route &&
          path.startsWith(rule.pathPrefix) &&
          rule.contentTypes.any((listed) => listed.toLowerCase() == type),
    );
  }

  Object? _rewrite(Object? value, RegistryRecord record) {
    if (value is Map<String, dynamic>) return value.map((key, item) => MapEntry(key, _rewrite(item, record)));
    if (value is List<dynamic>) return value.map((item) => _rewrite(item, record)).toList();
    if (value is! String) return value;
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    final pin = _pinFor(record, uri);
    if (pin == null) return value;
    return mirrorBase
        .replace(
          path: '/${pin.route}${uri.path}',
          query: uri.hasQuery ? uri.query : null,
          fragment: uri.hasFragment ? uri.fragment : null,
        )
        .toString();
  }

  Future<void> dispose() async => _client.close(force: true);
}
