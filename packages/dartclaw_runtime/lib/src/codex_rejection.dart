/// Why a ChatGPT backend refused a Codex turn.
///
/// Four unrelated failures that an operator must be able to tell apart, so no
/// value here is inferred from another's status code: a plan limit is not an
/// expired credential, and a broken mediation contract is neither.
enum CodexRejectionKind {
  /// The presented credential is no longer accepted.
  authExpired,

  /// The account's plan usage or rate limit is reached. Transient by nature —
  /// it carries no re-authentication and no contract meaning at all.
  usageLimit,

  /// The backend no longer accepts the auth scheme this mediation is built on,
  /// so the contract DartClaw pins against has moved, not the credential.
  contractBreak,

  /// The backend rejected the configured model for a ChatGPT account. DartClaw
  /// keeps no model catalogue: support is whatever the backend answers.
  modelUnsupported,
}

/// One classified backend refusal, ready for an operator to read.
final class CodexRejection {
  const new({required this.kind, required this.detail, this.model});

  final CodexRejectionKind kind;

  /// Credential-free operator text. Never carries the response body, which is
  /// backend-authored, nor any part of the credential presented.
  final String detail;

  /// The rejected model, for [CodexRejectionKind.modelUnsupported].
  final String? model;

  /// The diagnostic an operator sees, identical on both execution boundaries.
  String describe() => model == null ? detail : '$detail (model: $model)';
}

/// Classifies an upstream refusal, or returns `null` when it names none of the
/// four known causes.
///
/// A present [status] decides the buckets it can decide on its own, before any
/// marker is read: a 401 is the credential being refused and a 429 is the plan's
/// limit, whatever else the backend's prose happens to mention. Bodies are read
/// only for what no status distinguishes, so no bucket is ever reached through
/// another one's status code.
///
/// [status] is absent for a host-mode turn, where the vendor CLI surfaces the
/// backend's refusal as text rather than a response. [requestedModel] is the
/// model the turn asked for; it is the caller's own value, so a model-rejection
/// diagnostic names it exactly rather than parsing it back out of the refusal.
///
/// An unrecognized refusal stays unclassified: defaulting it into a bucket is
/// how a plan limit starts telling operators to log in again.
CodexRejection? classifyCodexRejection({int? status, required String body, String? requestedModel}) {
  if (status == 401) {
    return const CodexRejection(
      kind: CodexRejectionKind.authExpired,
      detail: 'the ChatGPT backend refused the stored subscription credential',
    );
  }

  if (status == 429) return _usageLimitRejection;

  final text = body.toLowerCase();

  // The contract break is the backend refusing the *scheme* the credential is
  // presented under, which makes everything else in the response moot: a model
  // named alongside it was never reached on the mediation this build pins.
  if (_namesAny(text, _contractBreakMarkers)) {
    return const CodexRejection(
      kind: CodexRejectionKind.contractBreak,
      detail:
          'the ChatGPT backend no longer accepts the bearer mediation this build pins against; '
          'upgrade DartClaw or run Codex on an OpenAI Platform API key',
    );
  }

  if (_rejectsTheRequest(status) &&
      (_namesAny(text, _modelRejectionMarkers) || (text.contains('model') && _namesAny(text, _rejectionPhrases)))) {
    return CodexRejection(
      kind: CodexRejectionKind.modelUnsupported,
      detail: 'the ChatGPT backend does not support the configured model for this account',
      model: _boundedModel(requestedModel),
    );
  }

  if (_namesAny(text, _usageLimitMarkers)) return _usageLimitRejection;

  return null;
}

const _usageLimitRejection = CodexRejection(
  kind: CodexRejectionKind.usageLimit,
  detail: 'the ChatGPT plan behind this credential has reached its usage limit; retry once it resets',
);

/// Whether [status] is the backend rejecting the request itself rather than
/// failing to serve it. A 5xx naming a model is the backend falling over while
/// a model happened to be in flight, not an answer about the account's models.
/// Absent for a host-mode turn, where there is no response to read.
bool _rejectsTheRequest(int? status) => status == null || (status >= 400 && status < 500);

bool _namesAny(String text, List<String> markers) => markers.any(text.contains);

/// A model name reaches an operator log, and on the mediated boundary it is
/// whatever the container put in its request body. Model identifiers are short
/// and printable, so anything else is truncated and stripped rather than
/// relayed — a container must not be able to write control characters or an
/// unbounded string into the host's diagnostics.
String? _boundedModel(String? model) {
  if (model == null) return null;
  final printable = model.replaceAll(RegExp(r'[^A-Za-z0-9._:@/-]'), '');
  if (printable.isEmpty) return null;
  return printable.length <= _maxModelLength ? printable : '${printable.substring(0, _maxModelLength)}…';
}

const _maxModelLength = 64;

const _modelRejectionMarkers = [
  'unsupported_model',
  'model_not_supported',
  'unsupported model',
  'unknown model',
  'invalid_model',
  'invalid model',
];

const _rejectionPhrases = ['not supported', 'does not support', 'is not available', 'not available for'];

const _contractBreakMarkers = [
  'use_agent_identity',
  'agent_identity',
  'agent identity',
  'agent_assertion',
  'unsupported_auth',
  'unsupported authorization',
  'authorization scheme',
];

const _usageLimitMarkers = [
  'usage_limit',
  'usage limit',
  'rate_limit',
  'rate limit',
  'quota',
  'plan limit',
  'plan_limit',
];
