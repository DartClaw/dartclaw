import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:path/path.dart' as p;

import 'canonical_tool.dart';
import 'process_types.dart';

typedef AcpPermissionDecision = Future<AcpPermissionResult> Function(AcpPermissionRequest request);

typedef AcpReverseCallAuditSink = void Function(AcpReverseCallAuditEvent event);

final class AcpReverseCallHandlers {
  AcpReverseCallHandlers({
    required this.cwd,
    this.guardChain,
    AcpPermissionDecision? permissionDecision,
    AcpReverseCallAuditSink? onAudit,
    ProcessFactory? terminalProcessFactory,
    Map<String, String>? baseEnvironment,
    this.hostOutputByteLimit = 65536,
  }) : _permissionDecision = permissionDecision,
       _onAudit = onAudit,
       _terminalProcessFactory = terminalProcessFactory,
       _baseEnvironment = Map<String, String>.unmodifiable(baseEnvironment ?? Platform.environment);

  final String cwd;
  final GuardChain? guardChain;
  final AcpPermissionDecision? _permissionDecision;
  final AcpReverseCallAuditSink? _onAudit;
  final ProcessFactory? _terminalProcessFactory;
  final Map<String, String> _baseEnvironment;
  final int hostOutputByteLimit;
  final Map<String, _AcpTerminal> _terminals = {};
  int _nextTerminalId = 0;

  Map<String, bool> get capabilityFlags => {'readTextFile': true, 'writeTextFile': true, 'terminal': true};

  Future<Map<String, dynamic>> readTextFile(Object? params) async {
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
  }

  Future<Map<String, dynamic>> writeTextFile(Object? params) async {
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
  }

  Future<Map<String, dynamic>> createTerminal(Object? params) async {
    final request = _request(params);
    final command = _requiredString(request, 'command', 'terminal/create');
    final terminalCwd = _resolveWorkspacePath(_optionalString(request, 'cwd') ?? '.', 'terminal/create');
    final envOverlay = _optionalStringMap(request, 'env', 'terminal/create');
    final requestedLimit = _optionalPositiveInt(request, 'outputByteLimit', 'terminal/create');
    final effectiveLimit = requestedLimit == null ? hostOutputByteLimit : requestedLimit.clamp(0, hostOutputByteLimit);
    final sanitizedEnvironment = SafeProcess.sanitize(
      baseEnvironment: {..._baseEnvironment, ...envOverlay},
      allowlist: defaultBashStepEnvAllowlist,
    );
    final verdict = await _evaluateGuard(
      method: 'terminal/create',
      canonicalTool: CanonicalTool.shell,
      input: {'command': command, 'cwd': terminalCwd},
    );
    if (verdict.isBlock) {
      return _noAccess(verdict.message);
    }

    final process = await _startTerminalProcess(command, terminalCwd, sanitizedEnvironment);
    final id = 'terminal-${++_nextTerminalId}';
    final terminal = _AcpTerminal(id: id, process: process, outputByteLimit: effectiveLimit);
    terminal.attachOutput();
    _terminals[id] = terminal;
    return {'terminalId': id, 'outputByteLimit': effectiveLimit};
  }

  Future<Map<String, dynamic>> terminalOutput(Object? params) async {
    final terminal = _terminalFor(params, 'terminal/output');
    _audit(method: 'terminal/output');
    return {'output': terminal.output, 'truncated': terminal.truncated};
  }

  Future<Map<String, dynamic>> waitForExit(Object? params) async {
    final terminal = _terminalFor(params, 'terminal/wait_for_exit');
    _audit(method: 'terminal/wait_for_exit');
    return {'exitCode': await terminal.process.exitCode, 'output': terminal.output, 'truncated': terminal.truncated};
  }

  Future<Map<String, dynamic>> killTerminal(Object? params) async {
    final terminal = _terminalFor(params, 'terminal/kill');
    _audit(method: 'terminal/kill');
    return {'ok': terminal.process.kill()};
  }

  Future<Map<String, dynamic>> releaseTerminal(Object? params) async {
    final terminal = _terminalFor(params, 'terminal/release');
    _audit(method: 'terminal/release');
    _terminals.remove(terminal.id);
    terminal.process.kill();
    return {'ok': true};
  }

  Future<void> disposeTerminals() async {
    final terminals = List<_AcpTerminal>.from(_terminals.values);
    _terminals.clear();
    for (final terminal in terminals) {
      terminal.process.kill();
    }
  }

  Future<Map<String, dynamic>> requestPermission(Object? params) async {
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

  int? _optionalPositiveInt(Map<String, dynamic> request, String key, String method) {
    final value = request[key];
    if (value == null) return null;
    if (value is int && value >= 0) return value;
    _audit(method: method);
    throw json_rpc.RpcException.invalidParams('ACP "$method" field "$key" must be a non-negative integer');
  }

  Map<String, String> _optionalStringMap(Map<String, dynamic> request, String key, String method) {
    final value = request[key];
    if (value == null) return const <String, String>{};
    if (value is! Map) {
      _audit(method: method);
      throw json_rpc.RpcException.invalidParams('ACP "$method" field "$key" must be an object');
    }
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String) {
        _audit(method: method);
        throw json_rpc.RpcException.invalidParams('ACP "$method" env entries must be strings');
      }
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }

  String _resolveWorkspacePath(String requestedPath, String method) {
    final root = _resolveExistingPath(cwd, method);
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
    final chain = guardChain;
    if (chain == null) return GuardVerdict.pass();
    return chain.evaluateBeforeToolCall(canonicalTool.stableName, input, rawProviderToolName: method);
  }

  Future<Process> _startTerminalProcess(String command, String workingDirectory, Map<String, String> environment) {
    final factory = _terminalProcessFactory;
    if (factory != null) {
      return factory(
        command,
        const <String>[],
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: false,
      );
    }
    return SafeProcess.start(
      command,
      const <String>[],
      env: EnvPolicy.sanitize(extraEnvironment: environment),
      workingDirectory: workingDirectory,
      baseEnvironment: const <String, String>{},
      runInShell: true,
    );
  }

  _AcpTerminal _terminalFor(Object? params, String method) {
    final request = _request(params);
    final id = _requiredString(request, 'terminalId', method);
    final terminal = _terminals[id];
    if (terminal == null) {
      _audit(method: method);
      throw json_rpc.RpcException(-32600, 'Unknown ACP terminal "$id"');
    }
    terminal.attachOutput();
    return terminal;
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

final class _AcpTerminal {
  _AcpTerminal({required this.id, required this.process, required this.outputByteLimit});

  final String id;
  final Process process;
  final int outputByteLimit;
  final _output = <int>[];
  bool _attached = false;
  bool truncated = false;

  String get output => utf8.decode(_output, allowMalformed: true);

  void attachOutput() {
    if (_attached) return;
    _attached = true;
    process.stdout.listen(_appendChunk);
    process.stderr.listen(_appendChunk);
  }

  void _appendChunk(List<int> chunk) {
    if (truncated) return;
    final remaining = outputByteLimit - _output.length;
    if (remaining <= 0) {
      truncated = true;
      return;
    }
    if (chunk.length > remaining) {
      _output.addAll(chunk.take(remaining));
      truncated = true;
      return;
    }
    _output.addAll(chunk);
  }
}
