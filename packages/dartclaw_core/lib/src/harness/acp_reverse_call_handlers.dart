import 'dart:async';
import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:path/path.dart' as p;

import 'canonical_tool.dart';

typedef AcpPermissionDecision = Future<AcpPermissionResult> Function(AcpPermissionRequest request);

typedef AcpReverseCallAuditSink = void Function(AcpReverseCallAuditEvent event);

final class AcpReverseCallHandlers {
  AcpReverseCallHandlers({this.guardChain, AcpPermissionDecision? permissionDecision, AcpReverseCallAuditSink? onAudit})
    : _permissionDecision = permissionDecision,
      _onAudit = onAudit;

  final GuardChain? guardChain;
  final AcpPermissionDecision? _permissionDecision;
  final AcpReverseCallAuditSink? _onAudit;
  _AcpTurnBinding? _activeTurn;

  Map<String, bool> get capabilityFlags => {'readTextFile': true, 'writeTextFile': true, 'terminal': false};

  /// Whether terminal subprocesses remain owned until their exit is observed.
  bool get ownsTerminals => false;

  /// Binds reverse calls to the authorization and workspace of an active turn.
  void bindTurn({required String sessionId, required String effectiveDirectory}) {
    final root = _resolveExistingPath(effectiveDirectory, 'session/bind');
    _activeTurn = _AcpTurnBinding(sessionId: sessionId, workspaceRoot: root);
  }

  /// Stops admitting reverse calls, drains accepted calls, then removes the binding.
  Future<void> unbindTurn(String sessionId) async {
    final activeTurn = _activeTurn;
    if (activeTurn == null || activeTurn.sessionId != sessionId) return;
    await activeTurn.close();
    if (identical(_activeTurn, activeTurn)) _activeTurn = null;
  }

  Future<Map<String, dynamic>> readTextFile(Object? params) => _runReverseCall('fs/read_text_file', () async {
    final request = _request(params);
    final path = _requiredString(request, 'path', 'fs/read_text_file');
    final resolvedPath = _resolveWorkspacePath(path, 'fs/read_text_file');
    final verdict = await _evaluateGuard(
      method: 'fs/read_text_file',
      canonicalTool: CanonicalTool.fileRead,
      input: {'path': resolvedPath},
    );
    if (verdict.isBlock) {
      return _noAccess(verdict.message);
    }
    final content = await File(resolvedPath).readAsString();
    return {'content': content};
  });

  Future<Map<String, dynamic>> writeTextFile(Object? params) => _runReverseCall('fs/write_text_file', () async {
    final request = _request(params);
    final path = _requiredString(request, 'path', 'fs/write_text_file');
    final content = _requiredString(request, 'content', 'fs/write_text_file');
    final resolvedPath = _resolveWorkspacePath(path, 'fs/write_text_file');
    final verdict = await _evaluateGuard(
      method: 'fs/write_text_file',
      canonicalTool: CanonicalTool.fileWrite,
      input: {'path': resolvedPath, 'content': content},
    );
    if (verdict.isBlock) {
      return _noAccess(verdict.message);
    }
    await File(resolvedPath).parent.create(recursive: true);
    await File(resolvedPath).writeAsString(content);
    return {'ok': true};
  });

  Future<Map<String, dynamic>> createTerminal(Object? params) =>
      _runReverseCall('terminal/create', () async => _terminalUnavailable('terminal/create'));

  Future<Map<String, dynamic>> terminalOutput(Object? params) =>
      _runReverseCall('terminal/output', () async => _terminalUnavailable('terminal/output'));

  Future<Map<String, dynamic>> waitForExit(Object? params) =>
      _runReverseCall('terminal/wait_for_exit', () async => _terminalUnavailable('terminal/wait_for_exit'));

  Future<Map<String, dynamic>> killTerminal(Object? params) =>
      _runReverseCall('terminal/kill', () async => _terminalUnavailable('terminal/kill'));

  Future<Map<String, dynamic>> releaseTerminal(Object? params) =>
      _runReverseCall('terminal/release', () async => _terminalUnavailable('terminal/release'));

  /// Requests termination of every owned terminal and reports whether all exits were confirmed.
  Future<bool> disposeTerminals() async => true;

  Future<Map<String, dynamic>> requestPermission(Object? params) =>
      _runReverseCall('session/request_permission', () async {
        final request = _request(params);
        final operation = _optionalString(request, 'operation') ?? _optionalString(request, 'tool') ?? 'unknown';
        final decisionHandler = _permissionDecision;
        _audit(method: 'session/request_permission', canonicalToolName: operation);
        if (decisionHandler == null) {
          return const {'granted': false, 'reason': 'Permission denied'};
        }
        try {
          final decision = await decisionHandler(AcpPermissionRequest(operation: operation, params: request));
          return {'granted': decision.granted, if (decision.reason != null) 'reason': decision.reason};
        } catch (error) {
          return {'granted': false, 'reason': 'Permission handler error: $error'};
        }
      });

  Future<T> _runReverseCall<T>(String method, Future<T> Function() operation) async {
    final activeTurn = _requireActiveTurn(method);
    activeTurn.beginCall(method);
    try {
      return await operation();
    } finally {
      activeTurn.endCall();
    }
  }

  Map<String, dynamic> _request(Object? params) {
    final value = params is json_rpc.Parameters ? params.value : params;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    throw json_rpc.RpcException.invalidParams('ACP request params must be an object');
  }

  String _requiredString(Map<String, dynamic> request, String key, String method) {
    final value = request[key];
    if (value is String && value.isNotEmpty) return value;
    _audit(method: method);
    throw json_rpc.RpcException.invalidParams('ACP "$method" requires string "$key"');
  }

  String? _optionalString(Map<String, dynamic> request, String key) {
    final value = request[key];
    if (value == null) return null;
    if (value is String && value.isNotEmpty) return value;
    throw json_rpc.RpcException.invalidParams('ACP request field "$key" must be a string');
  }

  String _resolveWorkspacePath(String requestedPath, String method) {
    final root = _requireActiveTurn(method).workspaceRoot;
    final candidate = p.normalize(p.absolute(root, requestedPath));
    final resolvedCandidate = _resolveCandidatePath(candidate, method);
    if (resolvedCandidate != root && !p.isWithin(root, resolvedCandidate)) {
      _audit(method: method);
      throw json_rpc.RpcException(-32600, 'ACP "$method" path escapes workspace');
    }
    return resolvedCandidate;
  }

  String _resolveCandidatePath(String candidate, String method) {
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound) {
      return _resolveExistingPath(candidate, method);
    }
    final existingParent = _nearestExistingParent(candidate, method);
    final parentResolved = _resolveExistingPath(existingParent, method);
    final relative = p.relative(candidate, from: existingParent);
    return p.normalize(p.join(parentResolved, relative));
  }

  String _nearestExistingParent(String candidate, String method) {
    var current = p.normalize(candidate);
    while (true) {
      final parent = p.dirname(current);
      if (parent == current) {
        _audit(method: method);
        throw json_rpc.RpcException(-32600, 'ACP "$method" path has no existing parent');
      }
      if (FileSystemEntity.typeSync(parent) != FileSystemEntityType.notFound) {
        return parent;
      }
      current = parent;
    }
  }

  String _resolveExistingPath(String path, String method) {
    try {
      return switch (FileSystemEntity.typeSync(path)) {
        FileSystemEntityType.directory => Directory(path).resolveSymbolicLinksSync(),
        FileSystemEntityType.link => Link(path).resolveSymbolicLinksSync(),
        _ => File(path).resolveSymbolicLinksSync(),
      };
    } on FileSystemException catch (error) {
      _audit(method: method);
      throw json_rpc.RpcException(-32600, 'ACP "$method" path resolution failed: ${error.message}');
    }
  }

  Future<GuardVerdict> _evaluateGuard({
    required String method,
    required CanonicalTool canonicalTool,
    required Map<String, dynamic> input,
  }) async {
    _audit(method: method, canonicalToolName: canonicalTool.stableName);
    final activeTurn = _requireActiveTurn(method);
    final chain = guardChain;
    if (chain == null) return GuardVerdict.pass();
    return chain.evaluateBeforeToolCall(
      canonicalTool.stableName,
      input,
      rawProviderToolName: method,
      sessionId: activeTurn.sessionId,
    );
  }

  Never _terminalUnavailable(String method) {
    _audit(method: method);
    throw json_rpc.RpcException(
      -32600,
      'ACP terminal reverse calls are unavailable until process-tree containment is implemented',
    );
  }

  _AcpTurnBinding _requireActiveTurn(String method) {
    final activeTurn = _activeTurn;
    if (activeTurn != null && activeTurn.acceptingCalls) return activeTurn;
    _audit(method: method);
    throw json_rpc.RpcException(-32600, 'ACP "$method" requires an active host turn');
  }

  Map<String, dynamic> _noAccess(String? reason) {
    final response = <String, dynamic>{'noAccess': true};
    if (reason != null) {
      response['reason'] = reason;
    }
    return response;
  }

  void _audit({required String method, String? canonicalToolName}) {
    _onAudit?.call(AcpReverseCallAuditEvent(rawProviderToolName: method, canonicalToolName: canonicalToolName));
  }
}

final class _AcpTurnBinding {
  _AcpTurnBinding({required this.sessionId, required this.workspaceRoot});

  final String sessionId;
  final String workspaceRoot;
  var acceptingCalls = true;
  var _inFlightCalls = 0;
  Completer<void>? _drained;

  void beginCall(String method) {
    if (!acceptingCalls) {
      throw json_rpc.RpcException(-32600, 'ACP "$method" requires an active host turn');
    }
    _inFlightCalls++;
  }

  void endCall() {
    _inFlightCalls--;
    if (!acceptingCalls && _inFlightCalls == 0) {
      _drained?.complete();
      _drained = null;
    }
  }

  Future<void> close() {
    acceptingCalls = false;
    if (_inFlightCalls == 0) return Future<void>.value();
    return (_drained ??= Completer<void>()).future;
  }
}

final class AcpPermissionRequest {
  final String operation;
  final Map<String, dynamic> params;

  const AcpPermissionRequest({required this.operation, required this.params});
}

final class AcpPermissionResult {
  final bool granted;
  final String? reason;

  const AcpPermissionResult({required this.granted, this.reason});
}

final class AcpReverseCallAuditEvent {
  final String rawProviderToolName;
  final String? canonicalToolName;

  const AcpReverseCallAuditEvent({required this.rawProviderToolName, this.canonicalToolName});
}
