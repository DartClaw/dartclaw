import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

GuardContext _ctx({
  required String hookPoint,
  String? toolName,
  String? rawProviderToolName,
  String? sessionId,
  Map<String, dynamic>? toolInput,
}) {
  return GuardContext(
    hookPoint: hookPoint,
    toolName: toolName,
    rawProviderToolName: rawProviderToolName,
    toolInput: toolInput,
    sessionId: sessionId,
    timestamp: DateTime.now(),
  );
}

void main() {
  group('TaskToolFilterGuard', () {
    late TaskToolFilterGuard guard;

    setUp(() {
      guard = TaskToolFilterGuard();
    });

    test('null allowedTools — all tools pass', () async {
      guard.allowedTools = null;
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isPass, isTrue);
    });

    test('empty allowedTools — all tools pass', () async {
      guard.allowedTools = [];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isPass, isTrue);
    });

    test('tool in allowedTools — pass', () async {
      guard.allowedTools = ['shell', 'file_read'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isPass, isTrue);
    });

    test('tool not in allowedTools — block with message', () async {
      guard.allowedTools = ['file_read'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isBlock, isTrue);
      expect(verdict.message, contains('shell'));
      expect(verdict.message, contains('file_read'));
    });

    test('closed policy permits Claude tool discovery but not discovered capabilities', () async {
      guard.allowedTools = ['web_search'];

      final discovery = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'),
      );
      final allowedSearch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_search', rawProviderToolName: 'WebSearch'),
      );
      final unrelatedFetch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', rawProviderToolName: 'WebFetch'),
      );

      expect(discovery.isPass, isTrue);
      expect(allowedSearch.isPass, isTrue);
      expect(unrelatedFetch.isBlock, isTrue);
    });

    test('Claude tool discovery requires matching raw and canonical identities', () async {
      guard.allowedTools = ['memory_apply'];

      final rawMismatch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'shell', rawProviderToolName: 'ToolSearch'),
      );
      final canonicalMismatch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'Bash'),
      );

      expect(rawMismatch.isBlock, isTrue);
      expect(canonicalMismatch.isBlock, isTrue);
    });

    test('tool discovery remains blocked for a toolless policy', () async {
      guard.allowedTools = ['__knowledge_inbox_no_tools__'];

      final verdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'),
      );

      expect(verdict.isBlock, isTrue);
    });

    test('sentinel allowlist blocks read and network tools for toolless turns', () async {
      guard.allowedTools = ['__knowledge_inbox_no_tools__'];

      final fileVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'file_read'));
      final networkVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch'));

      expect(fileVerdict.isBlock, isTrue);
      expect(networkVerdict.isBlock, isTrue);
    });

    test('toolless sentinel dominates a mixed global allowlist', () async {
      guard.allowedTools = ['__knowledge_inbox_no_tools__', 'file_read'];

      final fileVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'file_read'));
      final discoveryVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'),
      );

      expect(fileVerdict.isBlock, isTrue);
      expect(discoveryVerdict.isBlock, isTrue);
    });

    test('mcp_call in allowedTools — pass', () async {
      guard.allowedTools = ['shell', 'file_read', 'mcp_call'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'mcp_call'));
      expect(verdict.isPass, isTrue);
    });

    test('non-beforeToolCall hookPoint — always pass', () async {
      guard.allowedTools = ['file_read'];
      final messageCtx = GuardContext(hookPoint: 'messageReceived', timestamp: DateTime.now());
      final agentCtx = GuardContext(hookPoint: 'beforeAgentSend', timestamp: DateTime.now());
      expect((await guard.evaluate(messageCtx)).isPass, isTrue);
      expect((await guard.evaluate(agentCtx)).isPass, isTrue);
    });

    test('null toolName — pass', () async {
      guard.allowedTools = ['file_read'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: null));
      expect(verdict.isPass, isTrue);
    });

    test('allowedTools can be updated between turns', () async {
      guard.allowedTools = ['file_read'];
      expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'))).isBlock, isTrue);

      guard.allowedTools = null;
      expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'))).isPass, isTrue);
    });

    test('session tool filters only affect the matching active session', () async {
      guard.setSessionToolFilter('inbox-session', ['__knowledge_inbox_no_tools__']);

      final inboxVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: 'inbox-session'),
      );
      final interactiveVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: 'interactive-session'),
      );

      expect(inboxVerdict.isBlock, isTrue);
      expect(interactiveVerdict.isPass, isTrue);

      guard.setSessionToolFilter('inbox-session', null);
      expect(
        (await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: 'inbox-session')))
            .isPass,
        isTrue,
      );
    });

    test('toolless sentinel dominates a mixed session allowlist', () async {
      guard.setSessionToolFilter('inbox-session', ['__knowledge_inbox_no_tools__', 'file_read']);

      final fileVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'file_read', sessionId: 'inbox-session'),
      );
      final discoveryVerdict = await guard.evaluate(
        _ctx(
          hookPoint: 'beforeToolCall',
          toolName: 'claude:ToolSearch',
          rawProviderToolName: 'ToolSearch',
          sessionId: 'inbox-session',
        ),
      );
      final unrelatedSessionVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'file_read', sessionId: 'interactive-session'),
      );

      expect(fileVerdict.isBlock, isTrue);
      expect(discoveryVerdict.isBlock, isTrue);
      expect(unrelatedSessionVerdict.isPass, isTrue);
    });

    test('session read-only mode only affects the matching active session', () async {
      guard.setSessionReadOnly('inbox-session', true);

      final inboxVerdict = await guard.evaluate(
        _ctx(
          hookPoint: 'beforeToolCall',
          toolName: 'shell',
          sessionId: 'inbox-session',
          toolInput: {'command': 'touch generated.txt'},
        ),
      );
      final interactiveVerdict = await guard.evaluate(
        _ctx(
          hookPoint: 'beforeToolCall',
          toolName: 'shell',
          sessionId: 'interactive-session',
          toolInput: {'command': 'touch generated.txt'},
        ),
      );

      expect(inboxVerdict.isBlock, isTrue);
      expect(interactiveVerdict.isPass, isTrue);

      guard.setSessionReadOnly('inbox-session', false);
      expect(
        (await guard.evaluate(
          _ctx(
            hookPoint: 'beforeToolCall',
            toolName: 'shell',
            sessionId: 'inbox-session',
            toolInput: {'command': 'touch generated.txt'},
          ),
        )).isPass,
        isTrue,
      );
    });

    test('read-only policy blocks memory writes but permits retrieval', () async {
      guard.readOnly = true;

      for (final tool in ['memory_apply', 'memory_observe']) {
        expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: tool))).isBlock, isTrue);
      }
      for (final tool in ['memory_search', 'memory_read']) {
        expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: tool))).isPass, isTrue);
      }
    });

    test('read-only enforcement blocks the commands a mutating-command denylist let through', () async {
      guard.setSessionReadOnly('inbox-session', true);

      const bypasses = [
        'curl -o out.bin https://example.com',
        'dd if=/dev/zero of=f',
        'tar -xf a.tar',
        'python -c "open(\'f\',\'w\')"',
        'FOO=bar cat file',
        'cat \$(rm -rf /tmp/x)',
        'find . -delete',
        'cat a | tee b',
        'sudo cat /etc/passwd',
        // A separator the splitter must not miss, or everything after it is
        // read as an argument of the allowlisted first command.
        'echo hi\nrm -rf /tmp/victim',
        'cat README.md\nchmod 777 /etc/passwd',
        'echo hi & rm -rf /tmp/victim',
        // Binaries that can write a file or run another program.
        'awk \'BEGIN{system("rm -rf /tmp/victim")}\'',
        'sed \'1e rm -rf /tmp/victim\' README.md',
        'sort -o /tmp/out.txt /etc/passwd',
        'xxd -r payload.hex /tmp/out.bin',
        // `git` subcommands that mutate through an argument or an output flag.
        'git remote add evil https://example.com/e.git',
        'git remote set-url origin https://example.com/e.git',
        'git diff --output=/tmp/f',
        'git symbolic-ref HEAD refs/heads/attacker',
        // Quoting must not hide structure: an escaped quote is not a quote, and
        // a quoted argument is still inspected.
        r'echo \" > ./pwned \"',
        r'echo \" ; rm -f ./victim \"',
        'find . "-delete"',
        "find . '-exec' rm {} ';'",
        'git diff "--output=/tmp/pwned"',
        'git show "-o" /tmp/pwned',
        // Binaries that run another program or write through a flag.
        'rg --pre ./pre.sh hello ./f.txt',
        'rg --hostname-bin /tmp/evil.sh needle .',
        'git grep -O/tmp/evil.sh needle',
        'file -C -m mymagic',
        'less -o /tmp/out.log README.md',
        // An unterminated quote leaves a shape the parser cannot account for.
        "cat 'README.md",
      ];

      for (final command in bypasses) {
        final verdict = await guard.evaluate(
          _ctx(
            hookPoint: 'beforeToolCall',
            toolName: 'shell',
            sessionId: 'inbox-session',
            toolInput: {'command': command},
          ),
        );
        expect(verdict.isBlock, isTrue, reason: command);
        // The block names read-only enforcement, not a matched pattern.
        expect(verdict.message, contains('read-only'), reason: command);
      }
    });

    test('read-only enforcement still permits the discovery commands the contract names', () async {
      guard.setSessionReadOnly('inbox-session', true);

      const permitted = [
        'find docs -maxdepth 2 -type f',
        'test -f pubspec.yaml',
        'pwd',
        'git status',
        'git log --oneline',
        'cat README.md',
        'grep -r needle lib',
        'git status && grep -r needle lib',
        'cat README.md | head -5',
        'git remote',
        'git branch',
        'git symbolic-ref HEAD',
        // Operators inside a quoted argument are data, not structure.
        "grep 'foo|bar' lib",
        'grep -E "a|b" README.md',
        'grep "a>b" README.md',
        // A backslash escape inside a regex is argument text, not a shape the
        // parser must refuse.
        r"grep '\bword' README.md",
        'head -20 README.md',
      ];

      for (final command in permitted) {
        final verdict = await guard.evaluate(
          _ctx(
            hookPoint: 'beforeToolCall',
            toolName: 'shell',
            sessionId: 'inbox-session',
            toolInput: {'command': command},
          ),
        );
        expect(verdict.isPass, isTrue, reason: command);
      }
    });

    test('read-only enforcement blocks the git argument shapes that write, delete or exec', () async {
      guard.setSessionReadOnly('inbox-session', true);

      const bypasses = [
        // Config writes that never spend a non-flag argument slot.
        'git branch -uorigin/main',
        'git branch --set-upstream-to=origin/main',
        'git branch --unset-upstream',
        // Spawns \$GIT_EDITOR / core.editor.
        'git branch --edit-description',
        // Pre-subcommand globals are not part of any subcommand's flag set.
        'git --exec-path=/tmp/evil status',
        'git --config-env=core.editor=EV branch --edit-description',
        'git -c core.pager=/tmp/evil.sh log',
        'git --paginate log',
        // Ref deletion through a flag.
        'git symbolic-ref -d refs/heads/main',
        // `--help` execs `man` from PATH on every subcommand.
        'git status --help',
        'git log --help',
        'git branch --help',
        'git diff -h',
        // Runs the configured external diff / textconv / gpg program.
        'git log --ext-diff',
        'git diff --textconv',
        'git log --show-signature',
        'git show --show-signature HEAD',
        // A flag-shaped token after `--` is a ref or a path to git, so it
        // spends a positional slot rather than passing as an admitted flag.
        'git branch -- -a',
        'git branch -- --list',
        // Short options are matched whole, so an attached value or a bundle
        // blocks rather than being decomposed into flags that were never
        // separately admitted.
        'git symbolic-ref -qd HEAD',
        'git status -sb',
        'git log -n5',
        // Bare `git` names no subcommand.
        'git',
        // Still blocked: subcommands and positional shapes that mutate.
        'git branch newbranch',
        'git branch -d feature',
        'git checkout main',
        'git commit -m x',
      ];

      for (final command in bypasses) {
        final verdict = await guard.evaluate(
          _ctx(
            hookPoint: 'beforeToolCall',
            toolName: 'shell',
            sessionId: 'inbox-session',
            toolInput: {'command': command},
          ),
        );
        expect(verdict.isBlock, isTrue, reason: command);
        expect(verdict.message, contains('read-only'), reason: command);
      }
    });

    test('read-only enforcement still admits ordinary read-only git usage', () async {
      guard.setSessionReadOnly('inbox-session', true);

      const permitted = [
        'git status',
        'git status --porcelain=v2 --branch',
        'git log',
        'git log --oneline -20',
        'git log --oneline --graph --decorate',
        'git log --format=%H -- lib',
        'git diff',
        'git diff --cached --stat',
        'git show HEAD',
        'git show --name-only HEAD',
        'git branch',
        'git branch -a -v',
        'git branch --show-current',
        'git branch --contains=HEAD',
        'git rev-parse HEAD',
        'git rev-parse --abbrev-ref HEAD',
        'git blame -L 1,20 README.md',
        'git describe --tags',
        'git grep -n needle -- lib',
        // `-o` is `--others` for ls-files, not an output file.
        'git ls-files -o --exclude-standard',
        'git remote -v',
        'git symbolic-ref HEAD',
      ];

      for (final command in permitted) {
        final verdict = await guard.evaluate(
          _ctx(
            hookPoint: 'beforeToolCall',
            toolName: 'shell',
            sessionId: 'inbox-session',
            toolInput: {'command': command},
          ),
        );
        expect(verdict.isPass, isTrue, reason: command);
      }
    });

    test('a shell call the guard cannot read as a command blocks in a read-only session', () async {
      guard.setSessionReadOnly('inbox-session', true);

      for (final input in <Map<String, dynamic>>[
        {'command': ''},
        {
          'command': <String>['cat', 'README.md'],
        },
        <String, dynamic>{},
      ]) {
        final verdict = await guard.evaluate(
          _ctx(hookPoint: 'beforeToolCall', toolName: 'shell', sessionId: 'inbox-session', toolInput: input),
        );
        expect(verdict.isBlock, isTrue, reason: '$input');
        expect(verdict.message, contains('read-only'), reason: '$input');
      }
    });

    test('guard name and category', () {
      expect(guard.name, 'task_tool_filter');
      expect(guard.category, 'tool');
    });
  });
}
