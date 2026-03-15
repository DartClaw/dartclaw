import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'anthropic_api_classifier.dart';
import 'content_classifier.dart';

/// Typedef for subprocess creation — injectable for testing.
typedef ClassifierProcessFactory =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
      bool includeParentEnvironment,
    });

/// [ContentClassifier] that spawns `claude --print` for each classification.
///
/// Default classifier — works with OAuth or API-key auth (whatever the binary
/// is configured with). No `ANTHROPIC_API_KEY` required.
class ClaudeBinaryClassifier implements ContentClassifier {
  static final _log = Logger('ClaudeBinaryClassifier');
  static const _nestingEnvVars = ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'];

  /// Path or command name for the `claude` binary.
  final String claudeExecutable;

  /// Claude model name used for classification turns.
  final String model;
  final ClassifierProcessFactory _processFactory;

  /// Creates a classifier backed by `claude --print`.
  ClaudeBinaryClassifier({
    this.claudeExecutable = 'claude',
    this.model = 'claude-haiku-4-5-20251001',
    ClassifierProcessFactory? processFactory,
  }) : _processFactory = processFactory ?? Process.start;

  @override
  Future<String> classify(String content, {Duration timeout = const Duration(seconds: 15)}) async {
    final prompt =
        '${AnthropicApiClassifier.classificationPrompt}\n\n'
        'Classify this content:\n\n$content';

    // Build clean environment without nesting-detection vars
    final env = Map<String, String>.from(Platform.environment);
    for (final key in _nestingEnvVars) {
      env.remove(key);
    }

    final process = await _processFactory(
      claudeExecutable,
      ['--print', '--model', model, '--max-turns', '1', '-p', prompt],
      environment: env,
      includeParentEnvironment: false,
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
