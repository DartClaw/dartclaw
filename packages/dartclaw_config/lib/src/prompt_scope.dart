/// Scope that controls which workspace behavior files are included in the
/// system prompt for a given turn.
enum PromptScope {
  /// Full workspace behavior cascade.
  ///
  /// Includes SOUL.md, USER.md, TOOLS.md, errors.md, learnings.md, MEMORY.md,
  /// compact instructions, and AGENTS.md. Used for web chat, DM, group, and
  /// cron sessions where the full behavior context is appropriate.
  interactive,

  /// Lean task execution prompt.
  ///
  /// Includes SOUL.md (workspace) and TOOLS.md only. Excludes user/memory
  /// noise. Used for coding, writing, and automation tasks where a focused
  /// prompt reduces token waste and persona bleed.
  task,

  /// Sandboxed execution prompt.
  ///
  /// Includes TOOLS.md only — no workspace identity, no SOUL.md, no AGENTS.md.
  /// Used for research tasks running under the restricted security profile.
  restricted,

  /// Minimal independent evaluator prompt.
  ///
  /// Returns only the default prompt — no workspace behavior files, no
  /// AGENTS.md. Used for workflow review/analysis steps to prevent persona
  /// bleed from interactive state into independent evaluation.
  evaluator,
}
