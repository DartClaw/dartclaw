/// Shared constants and helpers for the `<workflow-context>` output protocol.
///
/// The agent-facing prompt (see [PromptAugmenter]) and the server-side parser
/// (see [ContextExtractor]) must agree on the exact tag spelling. Both sides
/// import from this file to avoid silent drift.
library;

/// Tag name used to delimit the workflow-context JSON payload in the
/// agent's final assistant message.
const String kWorkflowContextTag = 'workflow-context';

/// Opening tag literal.
const String kWorkflowContextOpen = '<$kWorkflowContextTag>';

/// Closing tag literal.
const String kWorkflowContextClose = '</$kWorkflowContextTag>';

/// Matches the `<workflow-context>...</workflow-context>` block and captures
/// its inner JSON payload in group 1.
final RegExp workflowContextRegExp = RegExp(
  '$kWorkflowContextOpen\\s*([\\s\\S]*?)\\s*$kWorkflowContextClose',
);
