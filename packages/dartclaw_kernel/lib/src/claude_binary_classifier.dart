import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'anthropic_api_classifier.dart';
import 'content_classifier.dart';
import 'safe_process.dart';

/// Typedef for subprocess creation — injectable so tests can observe the
/// resolved environment policy without spawning the binary.
typedef ClassifierProcessFactory = Future<Process> Function(
  String executable,
  List<String> arguments, {
  required EnvPolicy env,
  Map<String, String>? baseEnvironment,
});

/// [ContentClassifier] that spawns `claude --print` for each classification.
///
/// Default classifier — works with OAuth or API-key auth (whatever the binary
/// is configured with). No `ANTHROPIC_API_KEY` required; when the parent
/// environment carries one it is re-overlaid onto the sanitized child
/// environment, because sanitization strips `*_API_KEY` by default.
class ClaudeBinaryClassifier implements ContentClassifier {
  static final _log = Logger('ClaudeBinaryClassifier');

  /// Nesting-detection variables the child must not inherit.
  ///
  /// Expressed as sensitive patterns rather than an allowlist: the classifier
  /// keeps the rest of the parent environment, and an allowlist cannot express
  /// a removal.
  static const nestingEnvVars = ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'];

  static const _authEnvVar = 'ANTHROPIC_API_KEY';

  /// Path or command name for the `claude` binary.
  final String claudeExecutable;

  /// Claude model name used for classification turns.
  final String model;

  /// Parent environment the child environment is derived from.
  ///
  /// Defaults to the process environment; injectable for tests.
  final Map<String, String>? baseEnvironment;

  final ClassifierProcessFactory _processFactory;

  /// Creates a classifier backed by `claude --print`.
  new({
    this.claudeExecutable = 'claude',
    this.model = 'haiku',
    this.baseEnvironment,
    ClassifierProcessFactory? processFactory,
  }) : _processFactory = processFactory ?? SafeProcess.start;

  /// Environment policy applied to every classifier spawn.
  ///
  /// Sanitizes [parentEnvironment] with the default credential-shaped strip
  /// extended by [nestingEnvVars], then re-overlays the one credential the
  /// binary may need to authenticate.
  static EnvPolicy environmentPolicy(Map<String, String> parentEnvironment) {
    final apiKey = parentEnvironment[_authEnvVar];
    return EnvPolicy.sanitize(
      sensitivePatterns: [...defaultSensitivePatterns, ...nestingEnvVars],
      extraEnvironment: {_authEnvVar: ?apiKey},
    );
  }

  @override
  Future<String> classify(String content, {Duration timeout = const Duration(seconds: 15)}) async {
    final prompt =
        '${AnthropicApiClassifier.classificationPrompt}\n\n'
        'Classify this content:\n\n${AnthropicApiClassifier.frameContent(content)}';

    final process = await _processFactory(
      claudeExecutable,
      ['--print', '--model', model, '--max-turns', '1', '-p', prompt],
      env: environmentPolicy(baseEnvironment ?? Platform.environment),
      baseEnvironment: baseEnvironment,
    );

    final stdout = await process.stdout.transform(utf8.decoder).join().timeout(timeout);

    final exitCode = await process.exitCode.timeout(timeout);
    if (exitCode != 0) {
      final stderr = await process.stderr
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2))
          .catchError((_) => '');
      throw ProcessException(claudeExecutable, [], 'claude --print exited with code $exitCode: $stderr', exitCode);
    }

    final classification = stdout.trim().toLowerCase();

    if (!AnthropicApiClassifier.validCategories.contains(classification)) {
      _log.warning('Unexpected classification from claude binary: "$classification" — treating as unsafe');
      return 'harmful_content';
    }

    return classification;
  }
}
