import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'scheduled_job.dart';

/// How much of a failed command's stderr travels in the failure message.
const int _stderrTailBytes = 2000;

/// How long the output pipes may stay open once the command itself has
/// exited or been killed.
///
/// The pipes close on their last writer, not on the command: a grandchild that
/// inherited them keeps them open after the command is gone. Without a bound
/// the fire would never settle and `ScheduleService` would hold the job as
/// running for the life of the process. A close that follows the exit is
/// kernel-synchronous, so anything past this is a holder, not latency — and
/// cancelling the read end leaves that holder an EPIPE on its next write,
/// which is the right answer for a process the fire has already disowned.
const Duration _pipeCloseGrace = Duration(seconds: 2);

/// Why a `type: shell` firing did not produce a document.
///
/// Every arm throws rather than returning, so `ScheduleService` owns the retry
/// and the alert exactly as it does for any other callback job.
final class ShellJobFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs [definition]'s command and replaces [outputFile] with its stdout.
///
/// [environment] is the resolved secret map, overlaid *after* the sensitive-name
/// strip by [EnvPolicy.minimal] — pre-merging it into a base map would have the
/// strip remove the very variables this job exists to inject.
///
/// Returns the one-line summary the fire logs. Throws [ShellJobFailure] for
/// every outcome that is not a complete document — a non-zero exit, a timeout,
/// an output pipe held open past [_pipeCloseGrace] after exit, stdout past
/// [defaultProcessOutputLimitBytes], stdout that is not UTF-8, empty stdout, or
/// a failed write — leaving whatever [outputFile] already held untouched. Zero bytes is refused with the rest: a legitimately empty payload
/// is still `[]` or `{}`, and silently replacing a good feed with an empty file
/// would hand the agent an authoritative-looking empty answer with no alert.
Future<String> runShellJob({
  required String jobId,
  required ShellJobDefinition definition,
  required Map<String, String> environment,
  required File outputFile,
  required String workingDirectory,
}) async {
  final command = definition.command;
  final Process process;
  try {
    process = await SafeProcess.start(
      command.first,
      command.skip(1).toList(),
      env: EnvPolicy.minimal(extraEnvironment: environment),
      workingDirectory: workingDirectory,
    );
  } catch (error) {
    throw ShellJobFailure(_summary(jobId, 'could not start "${command.first}"', '$error'));
  }

  final stdout = _BoundedCapture(limit: defaultProcessOutputLimitBytes);
  final stderr = _TailCapture(limit: _stderrTailBytes);
  final subscriptions = [stdout.drain(process.stdout), stderr.drain(process.stderr)];
  final draining = Future.wait<void>(subscriptions.map((subscription) => subscription.asFuture<void>()));

  final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(definition.timeout);
  } on TimeoutException {
    await killWithEscalation(process, label: 'shell job "$jobId"');
    await _settle(draining, subscriptions).catchError((Object _) => false);
    throw ShellJobFailure(_summary(jobId, 'exceeded its ${definition.timeout.inSeconds}s timeout', stderr.text));
  }
  final bool pipesClosed;
  try {
    pipesClosed = await _settle(draining, subscriptions);
  } catch (error) {
    throw ShellJobFailure(_summary(jobId, 'output could not be read', '$error'));
  }

  if (exitCode != 0) throw ShellJobFailure(_summary(jobId, 'exited $exitCode', stderr.text));
  if (!pipesClosed) {
    // Whatever was captured cannot be called the whole document while another
    // process still holds the pipe.
    throw ShellJobFailure(
      _summary(jobId, 'left its output open ${_pipeCloseGrace.inSeconds}s after exiting', stderr.text),
    );
  }
  if (stdout.overLimit) {
    throw ShellJobFailure(_summary(jobId, 'wrote more than ${stdout.limit} bytes to stdout', stderr.text));
  }
  if (stdout.length == 0) throw ShellJobFailure(_summary(jobId, 'exited 0 without writing to stdout', stderr.text));

  final String document;
  try {
    document = utf8.decode(stdout.bytes);
  } on FormatException {
    throw ShellJobFailure(_summary(jobId, 'wrote stdout that is not valid UTF-8', stderr.text));
  }

  try {
    await outputFile.parent.create(recursive: true);
    await secureWriteFile(outputFile, document, restrictPermissions: true);
  } catch (error) {
    throw ShellJobFailure(_summary(jobId, 'output could not be written', '$error'));
  }
  return 'wrote ${stdout.length} bytes to feeds/${definition.output} (exit 0)';
}

/// Waits for [draining] within [_pipeCloseGrace]; `false` when the pipes are
/// still open at the bound, with every [subscriptions] entry cancelled so the
/// fire stops reading a stream nobody it started still owns.
Future<bool> _settle(Future<void> draining, List<StreamSubscription<List<int>>> subscriptions) async {
  try {
    await draining.timeout(_pipeCloseGrace);
    return true;
  } on TimeoutException {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    return false;
  }
}

/// Assembles the one-line fire report.
///
/// The collapse happens here, where the line is built, because [detail] is text
/// this pipeline never authored — a command's stderr or an OS error string can
/// carry the newline that would otherwise forge a second report line.
String _summary(String jobId, String cause, String detail) {
  final collapsed = detail.replaceAll(RegExp(r'\s+'), ' ').trim();
  return 'Shell job "$jobId" $cause${collapsed.isEmpty ? '' : ': $collapsed'}';
}

/// Accumulates a stream up to [limit] bytes, then counts without retaining.
class _BoundedCapture {
  new({required this.limit});

  final int limit;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int length = 0;
  bool overLimit = false;

  Uint8List get bytes => _bytes.toBytes();

  StreamSubscription<List<int>> drain(Stream<List<int>> stream) => stream.listen((chunk) {
    length += chunk.length;
    if (length > limit) {
      overLimit = true;
      _bytes.clear();
      return;
    }
    _bytes.add(chunk);
  });
}

/// Keeps the trailing [limit] bytes of a stream, decoded leniently.
///
/// Lenient because a killed process can be cut mid-character and a diagnostic
/// tail must not itself become the failure.
class _TailCapture {
  new({required this.limit});

  final int limit;
  final List<int> _tail = [];

  String get text => utf8.decode(_tail, allowMalformed: true);

  StreamSubscription<List<int>> drain(Stream<List<int>> stream) => stream.listen((chunk) {
    _tail.addAll(chunk);
    if (_tail.length > limit) _tail.removeRange(0, _tail.length - limit);
  });
}
