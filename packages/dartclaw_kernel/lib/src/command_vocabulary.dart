/// Shared shell-command classification vocabulary.
///
/// One source for the command names `FileGuard` (path-operation extraction)
/// and `TaskToolFilterGuard` (read-only enforcement) both reason about. These
/// are package-level constants rather than config-derived state: the two
/// consumers sit in different guard-chain layers, and a `guards.*` reload
/// replaces only the base layer — config-derived sets would desynchronize.
library;

/// Commands that read a path argument and can do nothing else.
const _plainReadCommands = {'cat', 'grep', 'head', 'tail', 'wc', 'stat', 'md5sum'};

/// Commands that read a path argument but can also write or shell out.
///
/// `file -C` compiles and writes a magic file; the pagers carry `-o` logging
/// and `!` / `LESSOPEN` shell escapes. They classify as reads for path policy,
/// but a read-only session must not invoke them.
const _unsafeReadCommands = {'less', 'more', 'file'};

/// Commands that read the file paths given as their arguments.
const fileReadCommands = {..._plainReadCommands, ..._unsafeReadCommands};

/// Commands that write the file paths given as their arguments.
const fileWriteCommands = {'tee', 'touch', 'chmod', 'chown', 'vi', 'vim', 'nano', 'mkdir', 'mktemp', 'install', 'ln'};

/// Commands that delete the file paths given as their arguments.
const fileDeleteCommands = {'rm', 'unlink', 'rmdir'};

/// Commands whose first argument is read and whose last argument is written.
const copyMoveCommands = {'cp', 'mv'};

/// The read-only argument policy for one admitted `git` subcommand.
///
/// [flags] enumerates every flag the subcommand may carry and [maxPositionals]
/// how many non-flag arguments it may take (`null` for unbounded).
typedef GitReadOnlyPolicy = ({Set<String> flags, int? maxPositionals});

/// Flags that shape how a commit listing is printed.
const _gitHistoryFormatFlags = {
  '--oneline',
  '--graph',
  '--decorate',
  '--no-decorate',
  '--abbrev-commit',
  '--no-abbrev-commit',
  '--abbrev',
  '--pretty',
  '--format',
  '--date',
  '--relative-date',
  '--parents',
  '--children',
  '--source',
  '--left-right',
  '--boundary',
  '--color',
  '--no-color',
  '--no-notes',
  '--notes',
  '-z',
};

/// Flags that select which commits a listing walks.
const _gitCommitSelectionFlags = {
  '--all',
  '--branches',
  '--tags',
  '--remotes',
  '--not',
  '--reverse',
  '--first-parent',
  '--merges',
  '--no-merges',
  '--min-parents',
  '--max-parents',
  '--author',
  '--committer',
  '--grep',
  '--since',
  '--after',
  '--until',
  '--before',
  '--max-count',
  '-n',
  '--skip',
  '--topo-order',
  '--date-order',
  '--author-date-order',
  '--follow',
  '--ancestry-path',
  '--full-history',
  '--simplify-merges',
  '--cherry-pick',
  '-g',
  '--walk-reflogs',
};

/// Flags that shape a diff.
///
/// `--ext-diff` and `--textconv` are absent, and their negations admitted, so a
/// caller can suppress a repo-configured external diff driver but not turn one
/// on for `log` and `show`. That bounds nothing for `diff`, where both are on
/// by default – repo config, not the command line, decides there. `--output` /
/// `-o` is absent because it writes the diff to a file.
const _gitDiffFlags = {
  '-p',
  '-u',
  '--patch',
  '--no-patch',
  '-s',
  '--stat',
  '--numstat',
  '--shortstat',
  '--dirstat',
  '--summary',
  '--name-only',
  '--name-status',
  '--raw',
  '--diff-filter',
  '-M',
  '-C',
  '--find-renames',
  '--find-copies',
  '--renames',
  '--no-renames',
  '-w',
  '-b',
  '--ignore-all-space',
  '--ignore-space-change',
  '--ignore-space-at-eol',
  '--ignore-blank-lines',
  '--word-diff',
  '--word-diff-regex',
  '--color-words',
  '-U',
  '--unified',
  '--function-context',
  '--src-prefix',
  '--dst-prefix',
  '--no-prefix',
  '--text',
  '--full-index',
  '--binary',
  '--exit-code',
  '--quiet',
  '--no-textconv',
  '--no-ext-diff',
  '-S',
  '-G',
  '--pickaxe-regex',
  '--pickaxe-all',
};

/// `git` subcommands a read-only session may run, and the arguments each may
/// carry.
///
/// An allowlist in both dimensions: a subcommand absent from this map blocks,
/// and so does any flag absent from that subcommand's set. `--help` is in no
/// set because it execs `man` from `PATH`; `-h` is in none either, so it blocks
/// with every other unlisted flag. A pre-subcommand global (`git --exec-path=…
/// status`) belongs to no subcommand's set and is rejected before this map is
/// consulted. A flag is matched whole unless it is a long flag carrying an
/// attached value, so a short option must be written separated and unbundled
/// (`-n 5`, not `-n5` or `-sb`). The one exception lives in the guard:
/// `git log -20` and its siblings are admitted as the `--max-count` shorthand.
///
/// Where [GitReadOnlyPolicy.maxPositionals] is finite, a value-taking flag must
/// be written in attached form (`--contains=HEAD`), because a separate value
/// spends a positional slot. That budget is what keeps `git branch <name>`,
/// `git remote add …` and `git symbolic-ref HEAD <ref>` out.
const readOnlyGitCommands = <String, GitReadOnlyPolicy>{
  'blame': (
    flags: {
      '-L',
      '-p',
      '--porcelain',
      '--line-porcelain',
      '--incremental',
      '-s',
      '-f',
      '--show-name',
      '-n',
      '--show-number',
      '-e',
      '--show-email',
      '-w',
      '-M',
      '-C',
      '-l',
      '--root',
      '--date',
      '--abbrev',
      '--reverse',
      '--first-parent',
    },
    maxPositionals: null,
  ),
  // Bare `git branch` lists. No positional argument is admitted, because every
  // one of them creates, deletes, renames or copies a branch.
  'branch': (
    flags: {
      '-a',
      '--all',
      '-r',
      '--remotes',
      '-v',
      '-vv',
      '--verbose',
      '--list',
      '--show-current',
      '--contains',
      '--no-contains',
      '--merged',
      '--no-merged',
      '--points-at',
      '--sort',
      '--format',
      '--color',
      '--no-color',
      '--column',
      '--no-column',
      '--abbrev',
      '--no-abbrev',
      '-i',
      '--ignore-case',
    },
    maxPositionals: 0,
  ),
  'describe': (
    flags: {
      '--all',
      '--tags',
      '--contains',
      '--abbrev',
      '--long',
      '--always',
      '--dirty',
      '--broken',
      '--match',
      '--exclude',
      '--first-parent',
      '--candidates',
      '--exact-match',
    },
    maxPositionals: null,
  ),
  'diff': (
    flags: {..._gitDiffFlags, '--cached', '--staged', '--merge-base', '--no-index', '--relative', '-R'},
    maxPositionals: null,
  ),
  'grep': (
    flags: {
      '-i',
      '--ignore-case',
      '-w',
      '--word-regexp',
      '-v',
      '--invert-match',
      '-E',
      '--extended-regexp',
      '-G',
      '--basic-regexp',
      '-P',
      '--perl-regexp',
      '-F',
      '--fixed-strings',
      '-n',
      '--line-number',
      '--column',
      '-l',
      '--files-with-matches',
      '--name-only',
      '-L',
      '--files-without-match',
      '-c',
      '--count',
      '-z',
      '--color',
      '--no-color',
      '--break',
      '--heading',
      '-p',
      '--show-function',
      '-A',
      '--after-context',
      '-B',
      '--before-context',
      '-C',
      '--context',
      '-W',
      '--function-context',
      '--threads',
      '-e',
      '-f',
      '--and',
      '--or',
      '--not',
      '--all-match',
      '--max-depth',
      '--no-index',
      '--untracked',
      '--cached',
      '--full-name',
      '-H',
    },
    maxPositionals: null,
  ),
  'log': (flags: {..._gitHistoryFormatFlags, ..._gitCommitSelectionFlags, ..._gitDiffFlags}, maxPositionals: null),
  'ls-files': (
    flags: {
      '-c',
      '--cached',
      '-d',
      '--deleted',
      '-m',
      '--modified',
      // `-o` is `--others` here, not an output file.
      '-o',
      '--others',
      '-i',
      '--ignored',
      '-s',
      '--stage',
      '-u',
      '--unmerged',
      '-k',
      '--killed',
      '-t',
      '-v',
      '-f',
      '-z',
      '--exclude',
      '--exclude-from',
      '--exclude-standard',
      '--full-name',
      '--directory',
      '--no-empty-directory',
      '--error-unmatch',
      '--abbrev',
      '--eol',
      '--deduplicate',
    },
    maxPositionals: null,
  ),
  // Bare `git remote` lists. `add`, `rename`, `remove`, `set-url`, `set-head`,
  // `prune` and `update` all arrive as positionals, and `show` reaches the
  // network, so none is admitted.
  'remote': (flags: {'-v', '--verbose'}, maxPositionals: 0),
  'rev-parse': (
    flags: {
      '--short',
      '--verify',
      '-q',
      '--quiet',
      '--abbrev-ref',
      '--symbolic',
      '--symbolic-full-name',
      '--show-toplevel',
      '--git-dir',
      '--git-common-dir',
      '--absolute-git-dir',
      '--show-prefix',
      '--show-cdup',
      '--is-inside-work-tree',
      '--is-inside-git-dir',
      '--is-bare-repository',
      '--show-object-format',
      '--all',
      '--branches',
      '--tags',
      '--remotes',
      '--not',
      '--default',
      '--revs-only',
      '--no-revs',
      '--flags',
      '--no-flags',
    },
    maxPositionals: null,
  ),
  'show': (flags: {..._gitHistoryFormatFlags, ..._gitDiffFlags}, maxPositionals: null),
  'status': (
    flags: {
      '-s',
      '--short',
      '-b',
      '--branch',
      '--porcelain',
      '--long',
      '-u',
      '--untracked-files',
      '--ignored',
      '--ignore-submodules',
      '-z',
      '--column',
      '--no-column',
      '--show-stash',
      '--ahead-behind',
      '--no-ahead-behind',
      '--renames',
      '--no-renames',
      '--find-renames',
      '-v',
      '--verbose',
    },
    maxPositionals: null,
  ),
  // `git symbolic-ref HEAD` reads; a second positional sets the ref and
  // `-d` deletes it.
  'symbolic-ref': (flags: {'--short', '-q', '--quiet'}, maxPositionals: 1),
};

/// Binaries a read-only session may invoke.
///
/// Deliberately an allowlist: anything absent is treated as mutating, so an
/// unrecognized binary blocks instead of falling through. `git` and `find` are
/// admitted separately, because they need argument inspection that a name
/// alone cannot express.
///
/// A command belongs here only if **no** invocation of it can write a file or
/// run another program. That excludes `awk` and `sed` (both execute shell
/// commands from their program text), `rg` (`--pre` and `--hostname-bin` run a
/// command), `file` and the pagers (see [_unsafeReadCommands]), and `sort`,
/// `uniq`, `tree` and `xxd` (each takes an output file). Their read-only uses
/// are covered by entries that carry no such flag.
const readOnlyShellCommands = {
  ..._plainReadCommands,
  // Discovery and navigation
  'find',
  'ls',
  'pwd',
  'test',
  'which',
  'basename',
  'dirname',
  'realpath',
  'readlink',
  'du',
  'df',
  // Text inspection
  'cut',
  'tr',
  'diff',
  'comm',
  'nl',
  'fold',
  'column',
  'fmt',
  'jq',
  'od',
  'strings',
  'sha1sum',
  'sha256sum',
  'shasum',
  'cksum',
  // Environment and identity
  'echo',
  'printf',
  'date',
  // `env` is deliberately absent: `env FOO=bar <cmd>` runs an arbitrary binary.
  'printenv',
  'uname',
  'whoami',
  'id',
  'hostname',
  'seq',
  'true',
  'false',
};
