import 'package:dartclaw_core/dartclaw_core.dart';

import 'auth_subcommand.dart';
import 'secret_input.dart';

/// Stores an operator-supplied Claude `setup-token` in the dedicated store.
///
/// The token is only ever read from stdin — piped, or a masked prompt — so no
/// option or positional can carry it into shell history, `ps` output, or a
/// crash dump.
class AuthClaudeCommand extends AuthSubcommand {
  static const _prompt = 'Paste the token printed by `claude setup-token` (input is masked), then press Enter:';

  final SecretTerminal _terminal;

  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment, SecretTerminal? terminal})
    : _terminal = terminal ?? const StdinSecretTerminal();

  @override
  String get name => 'claude';

  @override
  String get description => 'Store a Claude setup-token (issued by `claude setup-token`) for this DartClaw instance';

  @override
  Future<void> run() async {
    refuseArguments();
    final store = openStore(loadConfig().credentialsDir);
    final token = _readToken();
    final issuedAt = DateTime.now().toUtc();
    try {
      store.storeClaudeSetupToken(token, issuedAt: issuedAt);
    } catch (error) {
      // A creatable directory does not prove a writable one (a full or
      // read-only filesystem fails here), and the operator must be told the
      // token was not kept rather than meet a stack trace.
      stderrLine('Could not write ${store.claudeTokenPath}: ${AuthSubcommand.reasonFor(error)}. Nothing was stored.');
      exitFn(1);
    }
    final expiresAt = issuedAt.add(SubscriptionCredentialStore.claudeTokenLifetime);
    stdoutLine('Stored the Claude setup-token in ${store.claudeTokenPath}');
    stdoutLine(
      'Derived expiry ${expiresAt.toIso8601String().split('T').first} — renew by running `claude setup-token` '
      'again and re-running `$selfInvocation`.',
    );
  }

  /// Refuses input that is not a single token, naming the problem without
  /// reproducing any part of what was supplied.
  String _readToken() {
    var interrupted = false;
    final token =
        readSecretLine(
          _terminal,
          prompt: _prompt,
          writePrompt: stdoutLine,
          onInterrupt: () => interrupted = true,
        )?.trim() ??
        '';
    if (interrupted) {
      // 128 + SIGINT, and no message: the operator knows what they typed, and
      // "no token was supplied" would read as a rejection of their input.
      exitFn(130);
    } else if (token.isEmpty) {
      stderrLine('No token was supplied. Run `claude setup-token` and pass the value it prints to this command.');
      exitFn(1);
    } else if (RegExp(r'\s').hasMatch(token)) {
      stderrLine('The supplied value contains whitespace, so it is not a setup-token. Supply the token on its own.');
      exitFn(1);
    }
    return token;
  }
}
