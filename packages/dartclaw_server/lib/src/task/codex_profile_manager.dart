import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Manages a minimal, DartClaw-owned Codex profile directory so workflow
/// steps can run `codex exec` against a controlled environment instead of
/// the user's personal `~/.codex/` profile.
///
/// ## Why
///
/// Codex CLI injects a `<skills_instructions>` block into the developer
/// message of **every** turn, listing every `SKILL.md` it discovers under
/// `$CODEX_HOME/skills/` and `$HOME/.agents/skills/`. On a developer
/// machine with many globally-installed skills, this block can easily
/// exceed 5k tokens per turn. At 4 turns per step × many steps per
/// workflow, that's tens of thousands of input tokens per run spent
/// serializing skills the workflow never uses.
///
/// This manager creates an isolated profile dir seeded with just the
/// things Codex genuinely needs — primarily the OAuth credential
/// (`auth.json`) — so workflow runs see an empty skills registry and pay
/// only for the workflow-relevant skill the step actually invokes.
///
/// ## What gets seeded
///
/// * `auth.json` — symlinked from the source profile so OAuth continues
///   to work without re-login. Sharing behaviour depends on how Codex
///   writes refreshes — see "OAuth refresh" below.
/// * `.codex-global-state.json` — symlinked so Codex can resume any
///   user-level flags it has already negotiated.
/// * `skills/` — created empty; per-step skill injection is the caller's
///   responsibility (e.g. symlinking only the specific DartClaw skill the
///   step needs).
/// * `.agents/skills/` — created empty, so Codex's secondary skill
///   discovery path is also clean.
/// * `.gitconfig`, `.ssh`, `.gnupg` — symlinked from `sourceUserHome`
///   when they exist, so git/ssh/gpg invoked from inside a Codex turn
///   still see the user's identity, keys, and signing config. Missing
///   sources are skipped silently; this is a best-effort preservation
///   pass, not a hard requirement.
///
/// All other settings are intentionally omitted: `config.toml`, plugins,
/// MCP registrations, memories, sessions. Codex falls back to safe
/// defaults or skips them entirely.
///
/// ## OAuth refresh
///
/// The `auth.json` symlink assumes Codex refreshes credentials via
/// in-place writes (`open(O_TRUNC) + write`), which follow symlinks and
/// update the shared file. If Codex instead uses atomic rename
/// (`write tmp → rename over`), `rename(2)` replaces the link with a
/// regular file; the isolated profile then holds the fresh token while
/// `~/.codex/auth.json` grows stale. The behaviour has not been
/// integration-tested yet — treat token drift as a known risk.
///
/// ## Opt-in
///
/// This manager is not active by default. Callers opt in by passing
/// `isolated_profile: true` in the provider options (see
/// [WorkflowCliRunner]). Disabling it restores the previous behaviour of
/// using the user's `~/.codex/` as-is.
class CodexProfileManager {
  static final _log = Logger('CodexProfileManager');

  /// User-level files linked into the managed profile so subprocesses
  /// Codex spawns (git, ssh, gpg) still see the user's identity/keys.
  /// Best-effort — missing entries are skipped silently.
  static const _userHomeLinks = <String>['.gitconfig', '.ssh', '.gnupg'];

  /// Absolute path to the managed profile directory.
  final String profileDir;

  /// Absolute path to the source Codex home (typically `~/.codex`).
  final String sourceHome;

  /// Absolute path to the user's home directory — used to source
  /// `.gitconfig`, `.ssh`, `.gnupg` for symlinking into the managed
  /// profile so `HOME` override doesn't hide the user's identity from
  /// subprocesses Codex spawns.
  final String sourceUserHome;

  /// Memoised preparation future. The first caller kicks off the
  /// materialisation; every subsequent caller awaits the same future so
  /// we only do the work once even under concurrent invocation (parallel
  /// map iterations, multiple bound groups).
  Future<void>? _prepareFuture;

  CodexProfileManager({required this.profileDir, required this.sourceHome, required this.sourceUserHome});

  /// Resolves the default source home from the user's `HOME`.
  factory CodexProfileManager.forDataDir(String dataDir) {
    final home = Platform.environment['HOME'] ?? '';
    return CodexProfileManager(
      profileDir: p.join(dataDir, 'codex-profile'),
      sourceHome: p.join(home, '.codex'),
      sourceUserHome: home,
    );
  }

  /// Absolute path to the source `auth.json`.
  String get sourceAuthPath => p.join(sourceHome, 'auth.json');

  /// Whether the source `auth.json` is present — cheap synchronous check
  /// used by callers that want to validate the opt-in at construction
  /// time instead of per-turn.
  bool hasValidAuthSync() => File(sourceAuthPath).existsSync();

  /// Creates the profile dir and populates its credential symlinks.
  ///
  /// Idempotent — concurrent callers share a single in-flight
  /// materialisation via a memoised future, and repeated calls after
  /// completion are no-ops. Throws if the source `auth.json` does not
  /// exist, because running Codex without credentials would just fail
  /// silently at turn time with an unauthenticated error.
  Future<void> ensurePrepared() => _prepareFuture ??= _prepare();

  Future<void> _prepare() async {
    final profile = Directory(profileDir);
    await profile.create(recursive: true);
    await Directory(p.join(profileDir, 'skills')).create(recursive: true);
    await Directory(p.join(profileDir, '.agents', 'skills')).create(recursive: true);

    final sourceAuth = File(sourceAuthPath);
    if (!await sourceAuth.exists()) {
      throw StateError(
        'Cannot prepare isolated Codex profile at $profileDir: '
        'source auth.json not found at ${sourceAuth.path}. '
        'Log in with `codex login` first, or disable the isolated profile.',
      );
    }
    _log.fine(
      'auth.json is symlinked into the isolated profile — OAuth refresh sharing '
      'assumes Codex uses in-place writes. Atomic-rename refresh would strand '
      'fresh tokens in the managed profile and leave ~/.codex/auth.json stale.',
    );
    await _ensureSymlink(sourceAuth.path, p.join(profileDir, 'auth.json'));

    // `.codex-global-state.json` is optional — not all Codex versions
    // write it — but link it when present so the isolated profile
    // inherits any already-negotiated user-level flags.
    final sourceState = File(p.join(sourceHome, '.codex-global-state.json'));
    if (await sourceState.exists()) {
      await _ensureSymlink(sourceState.path, p.join(profileDir, '.codex-global-state.json'));
    }

    // Preserve user identity/keys/signing config for git/ssh/gpg
    // subprocesses launched inside Codex turns. `HOME` overrides the
    // user's real home, so without these links `git commit`/`git push`
    // would lose access to `~/.gitconfig`, `~/.ssh`, `~/.gnupg`.
    for (final name in _userHomeLinks) {
      await _linkUserHomeEntry(name);
    }

    _log.info('Prepared isolated Codex profile at $profileDir (source: $sourceHome, user: $sourceUserHome)');
  }

  /// Environment overrides to inject into the `codex` subprocess.
  ///
  /// Both `CODEX_HOME` and `HOME` are set so Codex's two skill-discovery
  /// paths (`$CODEX_HOME/skills/` and `$HOME/.agents/skills/`) resolve to
  /// the managed profile. User-level dotfiles (`.gitconfig`, `.ssh`,
  /// `.gnupg`) are symlinked during [ensurePrepared] so git/ssh/gpg
  /// subprocesses still see the user's identity.
  Map<String, String> envOverrides() {
    return {'CODEX_HOME': profileDir, 'HOME': profileDir};
  }

  Future<void> _linkUserHomeEntry(String name) async {
    if (sourceUserHome.isEmpty) return;
    final source = p.join(sourceUserHome, name);
    final sourceType = await FileSystemEntity.type(source, followLinks: false);
    if (sourceType == FileSystemEntityType.notFound) return;
    try {
      await _ensureSymlink(source, p.join(profileDir, name));
      _log.fine('Linked user $name into isolated profile ($source)');
    } on FileSystemException catch (error) {
      _log.warning('Could not link user $name into isolated profile: ${error.message}');
    }
  }

  Future<void> _ensureSymlink(String source, String target) async {
    final link = Link(target);
    if (await link.exists()) {
      final existingTarget = await link.target();
      if (existingTarget == source) return;
      await link.delete();
    } else if (await File(target).exists() || await Directory(target).exists()) {
      // Never silently replace a user-owned file/dir.
      throw StateError('Refusing to overwrite non-symlink at $target while preparing Codex profile');
    }
    try {
      await link.create(source);
    } on FileSystemException {
      // Cross-process race: another writer created the same symlink
      // between our exists() check and create(). Accept if the target
      // now matches; otherwise surface the original failure.
      if (await link.exists() && await link.target() == source) return;
      rethrow;
    }
  }
}
