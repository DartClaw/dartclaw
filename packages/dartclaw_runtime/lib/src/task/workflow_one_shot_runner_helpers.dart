part of 'workflow_one_shot_runner.dart';

extension _WorkflowOneShotRunnerHelpers on WorkflowOneShotRunner {
  Future<Task> _writeWorkflowTokenBreakdownToTaskConfig(
    Task task, {
    required int inputTokens,
    required int cacheReadTokens,
    required int outputTokens,
  }) async {
    final current = await _tasks.get(task.id);
    if (current == null || current.status.terminal) return current ?? task;
    final patch = WorkflowTaskConfig.taskConfigTokenBreakdownPatch(
      inputTokensNew: cacheReadTokens > inputTokens ? 0 : inputTokens - cacheReadTokens,
      cacheReadTokens: cacheReadTokens,
      outputTokens: outputTokens,
    );
    return _tasks.mergeConfigJson(current.id, patch);
  }
}

/// Why a finalizer reply was not the declared envelope.
enum _EnvelopeDefect { empty, notJson, notObject }

/// The finalizer envelope for a turn, or why the reply was not one.
sealed class _FinalizerEnvelope {
  const new();
}

final class _EnvelopeParsed extends _FinalizerEnvelope {
  const new(this.envelope);

  final Map<String, dynamic> envelope;
}

/// A rejected reply with parser details so a same-session re-ask can name the
/// defect instead of repeating a generic missing-envelope prompt.
final class _EnvelopeRejected extends _FinalizerEnvelope {
  const new(this.defect, {required this.body, this.parserMessage, this.offset});

  /// Characters of [body] quoted back around [offset].
  static const _excerptWindow = 120;

  final _EnvelopeDefect defect;
  final String body;
  final String? parserMessage;
  final int? offset;

  /// The recorded reason, distinguishing a reply that could not be read as the
  /// declared object from one that was never given.
  String get failureReason => switch (defect) {
    _EnvelopeDefect.empty => 'missing_envelope',
    _EnvelopeDefect.notJson => 'unparsable_envelope: $parserMessage (at character offset $offset)',
    _EnvelopeDefect.notObject => 'unparsable_envelope: reply is not the envelope object',
  };

  /// The re-ask suffix: the defect in one line, the parser's own position, and
  /// the reply around it.
  String get reAsk {
    final buffer = StringBuffer('Your previous response was not the required JSON envelope: $_defectLine');
    if (parserMessage != null) buffer.write('\nParser: $parserMessage (at character offset $offset).');
    if (body.isNotEmpty) buffer.write('\nYour previous response near that point:\n```\n$_excerpt\n```');
    buffer.write('\nOutput ONLY the JSON object now.');
    return buffer.toString();
  }

  String get _defectLine => switch (defect) {
    _EnvelopeDefect.empty => 'it was empty.',
    _EnvelopeDefect.notObject => 'it parsed as JSON but is not the envelope object.',
    // The bracket-balance hint only makes sense for a body that was attempting
    // JSON; a prose reply with a stray brace is not "the JSON object".
    _EnvelopeDefect.notJson => switch (_isJsonShaped(body) ? _unclosedContainers(body) : null) {
      final int unclosed => 'the JSON object is not closed: $unclosed unclosed `{`/`[`.',
      _ => '$parserMessage.',
    },
  };

  String get _excerpt {
    final at = offset ?? body.length;
    final atEnd = at >= body.length;
    var start = atEnd ? body.length - _excerptWindow : at - _excerptWindow ~/ 2;
    if (start < 0) start = 0;
    var end = atEnd ? body.length : at + _excerptWindow ~/ 2;
    if (end > body.length) end = body.length;
    return '${start > 0 ? '…' : ''}${body.substring(start, end)}${end < body.length ? '…' : ''}';
  }
}

/// Reads the one declared envelope contract once, then leaves validation to
/// `SchemaValidator` (ADR-031).
_FinalizerEnvelope _readFinalizerEnvelope(TurnOutcome outcome) {
  final provided = outcome.structuredOutput;
  if (provided != null) return _EnvelopeParsed(provided);
  final body = outcome.responseText?.trim() ?? '';
  if (body.isEmpty) return const _EnvelopeRejected(_EnvelopeDefect.empty, body: '');
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded.isEmpty) return _EnvelopeRejected(_EnvelopeDefect.notObject, body: body);
    return _EnvelopeParsed(decoded.map((key, value) => MapEntry(key.toString(), value)));
  } on FormatException catch (error) {
    return _EnvelopeRejected(
      _EnvelopeDefect.notJson,
      body: body,
      parserMessage: error.message,
      offset: error.offset ?? body.length,
    );
  }
}

/// Whether [body] (already trimmed) looks like it was attempting a JSON
/// object or array, as opposed to prose that happens to contain a brace.
bool _isJsonShaped(String body) => body.startsWith('{') || body.startsWith('[');

/// Containers left open at the end of [body], or null when balance is not the
/// defect — a mismatched or surplus closer and an unterminated string are each
/// something the parser's own message states better.
int? _unclosedContainers(String body) {
  final open = <int>[];
  var inString = false;
  var escaped = false;
  for (final code in body.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5c) {
        escaped = true;
      } else if (code == 0x22) {
        inString = false;
      }
      continue;
    }
    switch (code) {
      case 0x22:
        inString = true;
      case 0x7b || 0x5b:
        open.add(code);
      case 0x7d:
        if (open.isEmpty || open.removeLast() != 0x7b) return null;
      case 0x5d:
        if (open.isEmpty || open.removeLast() != 0x5b) return null;
    }
  }
  return inString || open.isEmpty ? null : open.length;
}
