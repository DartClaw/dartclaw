import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ProcessFactory;
import 'package:dartclaw_security/dartclaw_security.dart' show SafeProcess;

import '../version.dart' show dartclawVersion;

/// Drives the vendor Codex CLI's own non-interactive refresh against [codexHome].
///
/// Spawns `codex app-server`, handshakes, and asks for auth status. That request
/// routes through the vendor's own auth manager, which performs the token POST
/// and persists `auth.json` when the access token is inside its proactive
/// window. DartClaw therefore embeds no client id, no token endpoint and no
/// grant type, and never reads the refresh token — the value it would otherwise
/// have to keep out of every log.
///
/// Returns once the vendor has answered. The answer does not report refresh
/// failure, so whether the store actually became usable is confirmed by the
/// caller re-reading it, never by this result. Throws when the drive itself did
/// not complete — a spawn failure, a protocol error, or [timeout] elapsing.
///
/// [codexHome] is injected as an explicit overlay rather than inherited: the
/// sanitized base environment is stripped of credential-shaped variables, and
/// the store must be the one DartClaw owns regardless of what the operator
/// exported.
Future<void> refreshCodexAuth(
  String codexHome, {
  String executable = 'codex',
  Duration timeout = const Duration(seconds: 30),
  Map<String, String>? baseEnvironment,
  ProcessFactory? processFactory,
}) async {
  final start = processFactory ?? Process.start;
  final process = await start(
    executable,
    const ['app-server'],
    environment: SafeProcess.sanitize(
      baseEnvironment: baseEnvironment ?? Platform.environment,
      extraEnvironment: {'CODEX_HOME': codexHome},
    ),
    includeParentEnvironment: false,
  );
  final driving = _drive(process);
  try {
    await driving.timeout(timeout);
  } finally {
    process.kill();
    // A timed-out drive keeps running and then fails when the killed process
    // closes its streams. That failure belongs to a caller who has already gone
    // and must not surface as an unhandled asynchronous error.
    unawaited(driving.catchError((Object _) {}));
  }
}

const _initializeId = 1;
const _authStatusId = 2;

Future<void> _drive(Process process) async {
  // Only the request currently in flight is held here, so every failure this
  // map can deliver has an awaiter — a completer nobody listens to would fail
  // the whole isolate with an unhandled asynchronous error instead.
  final pending = <int, Completer<void>>{};
  // The app-server speaks newline-delimited JSON and neither sends nor expects
  // a `jsonrpc` member, so this is not quite JSON-RPC 2.0 on the wire.
  final subscription = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) => _completeAnswer(pending, line),
        onDone: () => _failPending(pending, 'the Codex app-server exited before answering'),
        onError: (Object error) => _failPending(pending, 'the Codex app-server stream failed'),
      );
  // Nothing here reads stderr for meaning, but an undrained pipe would block
  // the vendor process once it fills.
  unawaited(process.stderr.drain<void>().catchError((Object _) {}));
  // Writing to a process that already died surfaces on the sink rather than at
  // the call site; the drive fails through the stream instead, so the sink's
  // own error must not escape as an unhandled asynchronous error.
  unawaited(process.stdin.done.catchError((Object _) {}));
  try {
    await _ask(
      process,
      pending,
      id: _initializeId,
      method: 'initialize',
      params: {
        'clientInfo': {'name': 'dartclaw', 'version': dartclawVersion},
      },
    );
    process.stdin.writeln(jsonEncode({'method': 'initialized'}));
    // No refresh flag: the conditional form rotates only inside the vendor's own
    // proactive window, which makes it idempotent and safe on every use. No
    // token is requested back, so nothing secret crosses this pipe.
    await _ask(process, pending, id: _authStatusId, method: 'getAuthStatus', params: {'includeToken': false});
  } finally {
    await subscription.cancel();
  }
}

Future<void> _ask(
  Process process,
  Map<int, Completer<void>> pending, {
  required int id,
  required String method,
  required Map<String, Object?> params,
}) async {
  final answer = Completer<void>();
  pending[id] = answer;
  try {
    process.stdin.writeln(jsonEncode({'id': id, 'method': method, 'params': params}));
    await answer.future;
  } finally {
    pending.remove(id);
  }
}

void _completeAnswer(Map<int, Completer<void>> pending, String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return;
  }
  if (decoded is! Map<Object?, Object?>) return;
  // A response never carries `method`; the server's own requests share this id
  // space, and one numbered 1 or 2 would otherwise answer the handshake.
  if (decoded.containsKey('method')) return;
  final id = decoded['id'];
  if (id is! int) return;
  final answer = pending[id];
  if (answer == null || answer.isCompleted) return;
  if (decoded.containsKey('error')) {
    // The payload is vendor-authored and may quote request contents, so the
    // method is named and the body is not.
    answer.completeError(StateError('the Codex app-server refused the "${_methodOf(id)}" request'));
    return;
  }
  answer.complete();
}

String _methodOf(int id) => id == _initializeId ? 'initialize' : 'getAuthStatus';

void _failPending(Map<int, Completer<void>> pending, String reason) {
  for (final answer in pending.values) {
    if (!answer.isCompleted) answer.completeError(StateError(reason));
  }
}
