/// Scope that controls which workspace behavior files are included in the
/// system prompt for a given turn.
enum PromptScope {
  /// Primary human-facing conversation.
  ///
  /// Includes workspace identity, bounded personal memory, compact instructions,
  /// and AGENTS.md. Human input separately controls onboarding eligibility.
  primary,

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
}
