@Tags(['component'])
library;

import 'package:dartclaw_workflow/src/workflow/bash_step_runner.dart';
import 'package:test/test.dart';

void main() {
  group('validateBashCommandTemplate', () {
    for (final command in const [
      'echo {{context.command}} | sh',
      'printf %s {{PAYLOAD}} | /usr/bin/bash',
      'printf %s {{PAYLOAD}} | /opt/homebrew/bin/bash',
      "printf %s {{PAYLOAD}} | 'sh'",
      'printf %s {{PAYLOAD}} | "bash"',
      r'printf %s {{PAYLOAD}} | \s\h',
      'bash <<< {{PAYLOAD}}',
      '  eval {{context.command}}',
      'command eval {{PAYLOAD}}',
      'builtin eval {{PAYLOAD}}',
      'bash -c "printf %s {{context.command}}"',
      'bash -lc {{PAYLOAD}}',
      'printf %s {{PAYLOAD}} > payload.sh; sh payload.sh',
      'printf %s {{PAYLOAD}} | dash',
      'printf %s {{PAYLOAD}} | /usr/bin/zsh',
      'cat <<EOF\n{{PAYLOAD}}\nEOF',
      "cat <<'EOF'\n{{PAYLOAD}}\nEOF",
      'cat <<-EOF\n\t{{PAYLOAD}}\nEOF',
    ]) {
      test('rejects shell reparse: $command', () {
        expect(
          () => validateBashCommandTemplate(command),
          throwsA(isA<ArgumentError>().having((error) => error.message, 'message', contains('shell re-parsing'))),
        );
      });
    }

    test('rejects substitutions inside caller-owned shell quotes', () {
      expect(
        () => validateBashCommandTemplate('printf %s "{{context.value}}"'),
        throwsA(
          isA<ArgumentError>().having((error) => error.message, 'message', contains('caller-owned shell quoting')),
        ),
      );
    });

    test('allows substitutions as ordinary shell arguments', () {
      expect(() => validateBashCommandTemplate('printf %s {{context.value}}'), returnsNormally);
    });
  });
}
