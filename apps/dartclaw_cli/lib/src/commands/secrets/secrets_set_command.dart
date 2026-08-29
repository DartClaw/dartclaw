import 'package:dartclaw_config/dartclaw_config.dart';

import '../auth/secret_input.dart';
import '../credential_subcommand.dart';
import 'secrets_subcommand.dart';

/// Stores an operator-supplied named credential.
///
/// The value is only ever read from stdin — piped, or a masked prompt — so no
/// option or positional can carry it into shell history, `ps` output, or a
/// crash dump.
class SecretsSetCommand extends SecretsSubcommand {
  static const _apiKey = 'api-key';
  static const _githubToken = 'github-token';
  static const _prompt = 'Paste the credential value (input is masked), then press Enter:';

  final SecretTerminal _terminal;

  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment, SecretTerminal? terminal})
    : _terminal = terminal ?? const StdinSecretTerminal() {
    argParser
      ..addOption(
        'type',
        allowed: const [_apiKey, _githubToken],
        help: 'Credential type. Inferring it from the value would let a rotated token silently change an entry.',
      )
      ..addOption('repository', help: 'Repository policy for a $_githubToken entry, as org/name');
  }

  @override
  String get name => 'set';

  @override
  String get description => 'Store a named credential, reading the value from a masked prompt or from stdin';

  @override
  String get invocation => 'dartclaw secrets set <name> --type $_apiKey|$_githubToken';

  @override
  Future<void> run() async {
    final name = readNameArgument();
    final type = argResults!['type'] as String?;
    if (type == null) {
      // Not `mandatory: true`: that throws an ArgumentError out of the option
      // read rather than refusing with a message the operator can act on.
      stderrLine('--type is required: `$invocation`.');
      exitFn(1);
    }
    final repository = (argResults!['repository'] as String?)?.trim();
    if (repository != null && repository.isNotEmpty && type != _githubToken) {
      stderrLine('--repository applies to a $_githubToken entry only; this one is --type $type.');
      exitFn(1);
    }

    final store = openStore(loadDeclaredConfig().credentialsDir);
    final value = _readValue();
    final entry = type == _githubToken
        ? CredentialEntry.githubToken(
            token: value,
            repository: repository == null || repository.isEmpty ? null : repository,
          )
        : CredentialEntry(apiKey: value);
    try {
      store.write(name, entry);
    } catch (error) {
      // A creatable directory does not prove a writable one, and the operator
      // must be told the value was not kept rather than meet a stack trace.
      stderrLine(
        'Could not write ${store.pathFor(name)}: ${CredentialSubcommand.reasonFor(error)}. Nothing was stored.',
      );
      exitFn(1);
    }
    stdoutLine('Stored the $type credential "$name" in ${store.pathFor(name)}');
    stdoutLine('It resolves as `credentials.$name` at the next config load — no `credentials:` block is needed.');
  }

  /// Refuses input that is not a usable value, naming the problem without
  /// reproducing any part of what was supplied.
  String _readValue() {
    var interrupted = false;
    final raw = readSecretLine(
      _terminal,
      prompt: _prompt,
      writePrompt: stdoutLine,
      onInterrupt: () => interrupted = true,
    );
    if (interrupted) {
      // 128 + SIGINT, and no message: the operator knows what they typed, and
      // "no value was supplied" would read as a rejection of their input.
      exitFn(130);
    }
    // A piped line arrives without its terminator, but a CRLF pipe leaves the
    // carriage return, which would be stored as part of the secret.
    final value = (raw ?? '').replaceAll(RegExp(r'[\r\n]+$'), '');
    if (value.trim().isEmpty) {
      stderrLine('No value was supplied. Nothing was stored.');
      exitFn(1);
    }
    return value;
  }
}
