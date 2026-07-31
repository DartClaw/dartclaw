import 'dart:convert';

/// Returns HTML for the "New Task" dialog element.
///
/// Rendered as a `<dialog>` that can be opened via `showModal()`.
/// Form submission is handled by the static task/workflow JS modules.
///
/// When [projectOptions] is non-empty and contains at least one non-local
/// project, a project selector is shown between the Type and Description fields.
String newTaskFormDialogHtml({
  List<Map<String, String>> goalOptions = const [],
  List<Map<String, String>> projectOptions = const [],
}) {
  final escape = const HtmlEscape();
  final goalOptionsHtml = goalOptions
      .map(
        (goal) =>
            '<option value="${escape.convert(goal['value'] ?? '')}">'
            '${escape.convert(goal['label'] ?? goal['value'] ?? 'Goal')}</option>',
      )
      .join();
  final goalSelectMarkup = goalOptions.isEmpty
      ? '''
      <option value="" selected>No goal</option>
      <option value="" disabled>No goals available</option>
'''
      : '''
      <option value="" selected>No goal</option>
      $goalOptionsHtml
''';

  // Build project selector markup — only shown when external projects exist.
  final externalProjects = projectOptions.where((p) => p['value'] != '_local').toList();
  final projectSelectorMarkup = externalProjects.isEmpty ? '' : _buildProjectSelectorMarkup(projectOptions, escape);

  // Build workflow project selector options (no status indicator needed — user picks project for workflow).
  final workflowProjectOptionsHtml = externalProjects
      .map((p) {
        final value = escape.convert(p['value'] ?? '');
        final label = escape.convert(p['label'] ?? p['value'] ?? '');
        return '<option value="$value">$label</option>';
      })
      .join('\n              ');

  return '''
<dialog id="new-task-dialog" class="dialog dialog--md card card-glass">
  <form id="new-task-form" method="dialog">
    <div class="dialog-header">
      <h2 class="t-heading">New Task</h2>
      <button type="button" class="btn-close" aria-label="Close" data-task-dialog-close data-icon="x"></button>
    </div>

    <div class="tabs">
      <button type="button" class="tab t-label active" data-task-tab="single">Single Task</button>
      <button type="button" class="tab t-label" data-task-tab="workflow">Workflow</button>
    </div>

    <div class="dialog-body">
      <div class="tab-panel active" data-task-panel="single">
        <div class="form-field">
          <label class="form-label t-caption tracking-caps" for="task-title">Title</label>
          <input type="text" id="task-title" name="title" class="form-input" required
                 placeholder="Brief task title">
        </div>

        <div class="form-field">
          <label class="form-label t-caption tracking-caps" for="task-type-select">Type</label>
          <select id="task-type-select" name="type" class="form-select" data-enhance="custom-select" required>
            <option value="coding">Coding</option>
            <option value="research">Research</option>
            <option value="writing">Writing</option>
            <option value="analysis">Analysis</option>
            <option value="automation">Automation</option>
            <option value="custom">Custom</option>
          </select>
        </div>

        <div class="form-field">
          <div id="task-type-guidance" class="task-type-guidance">
            <p class="text-muted" data-task-type-hint>
              Coding tasks run in isolated git worktrees and produce diffs for review.
            </p>
          </div>
        </div>
$projectSelectorMarkup
        <div class="form-field">
          <label class="form-label t-caption tracking-caps" for="task-description" data-task-description-label>Description</label>
          <textarea id="task-description" name="description" class="form-textarea" required data-task-description-input
                    rows="3" placeholder="What should the agent do?"></textarea>
        </div>

        <div class="form-field">
          <label class="form-label t-caption tracking-caps" for="task-goal-select">Goal</label>
          <select id="task-goal-select" name="goalId" class="form-select" data-enhance="custom-select">
$goalSelectMarkup
          </select>
        </div>

        <div class="form-field">
          <label class="form-label t-caption tracking-caps" for="task-acceptance-criteria" data-task-criteria-label>Acceptance Criteria</label>
          <textarea id="task-acceptance-criteria" name="acceptanceCriteria" class="form-textarea" data-task-criteria-input
                    rows="3" placeholder="How will you know when it's done?"></textarea>
        </div>

        <details class="task-advanced-section">
          <summary class="form-label t-caption tracking-caps">Advanced</summary>
          <div class="task-advanced-fields">
            <div class="form-field">
              <label class="form-label t-caption tracking-caps" for="task-model">Model Override</label>
              <input type="text" id="task-model" name="model" class="form-input"
                     placeholder="default">
            </div>
            <div class="form-field">
              <label class="form-label t-caption tracking-caps" for="task-token-budget">Token Budget</label>
              <input type="number" id="task-token-budget" name="tokenBudget" class="form-input"
                     min="0" placeholder="No limit">
            </div>
            <fieldset class="form-field task-tool-allowlist">
              <legend class="form-label t-caption tracking-caps">Allowed Tools</legend>
              <p class="form-help-text">When checked, only selected tools are permitted. Leave all unchecked for default policy.</p>
              <div class="tool-checklist">
                <label><input type="checkbox" name="allowedTools" value="shell"> Shell</label>
                <label><input type="checkbox" name="allowedTools" value="file_read"> File Read</label>
                <label><input type="checkbox" name="allowedTools" value="file_write"> File Write</label>
                <label><input type="checkbox" name="allowedTools" value="file_edit"> File Edit</label>
                <label><input type="checkbox" name="allowedTools" value="web_fetch"> Web Fetch</label>
                <label><input type="checkbox" name="allowedTools" value="mcp_call"> MCP Call</label>
              </div>
            </fieldset>
            <div class="form-field">
              <label class="form-label t-caption tracking-caps" for="task-review-mode">Review Mode</label>
              <select id="task-review-mode" name="reviewMode" class="form-select" data-enhance="custom-select">
                <option value="" selected>Default</option>
                <option value="auto-accept">Auto-accept</option>
                <option value="mandatory">Mandatory review</option>
                <option value="coding-only">Coding-only</option>
              </select>
            </div>
          </div>
        </details>

        <label class="form-field form-field--checkbox">
          <input type="checkbox" class="form-checkbox" id="auto-start-checkbox" name="autoStart">
          <span>Start immediately</span>
        </label>
      </div>

      <div class="tab-panel" data-task-panel="workflow">
        <div id="workflow-list" class="workflow-list">
          <div class="workflow-list-loading" hidden>
            <div class="skeleton"></div>
            <div class="skeleton"></div>
            <div class="skeleton"></div>
          </div>
          <div class="workflow-list-empty" hidden>
            <p class="text-muted">No workflows available.</p>
          </div>
          <div class="workflow-list-cards"></div>
        </div>
        <div id="workflow-form" class="workflow-var-form" hidden>
          <div id="workflow-vars"></div>
          <div id="workflow-project-select" class="form-field" hidden>
            <label class="form-label t-caption tracking-caps" for="workflow-project">Project</label>
            <select id="workflow-project" class="form-select" data-enhance="custom-select">
              <option value="">Default project</option>
              $workflowProjectOptionsHtml
            </select>
          </div>
        </div>
      </div>
    </div>

    <div class="dialog-footer">
      <div id="new-task-error" class="form-error t-caption"></div>
      <div class="dialog-actions">
        <button type="button" class="btn btn-ghost" data-task-dialog-close>Cancel</button>
        <button type="submit" class="btn btn-primary" id="task-dialog-submit">Create Task</button>
      </div>
    </div>
  </form>
</dialog>
''';
}

String _buildProjectSelectorMarkup(List<Map<String, String>> projectOptions, HtmlEscape escape) {
  final optionsHtml = projectOptions
      .map((p) {
        final value = escape.convert(p['value'] ?? '');
        final status = p['status'] ?? 'ready';
        final label = escape.convert(p['label'] ?? '');
        final isDefault = p['isDefault'] == 'true';
        final isReady = status == 'ready';
        final statusIndicator = switch (status) {
          'ready' => ' ✓',
          'cloning' => ' (cloning)',
          'error' => ' (error)',
          'stale' => ' ⚠',
          _ => '',
        };
        final selectedAttr = isDefault ? ' selected' : '';
        final disabledAttr = isReady ? '' : ' disabled';
        return '<option value="$value"$selectedAttr$disabledAttr>$label$statusIndicator</option>';
      })
      .join('\n      ');

  return '''
      <div class="form-field">
        <label class="form-label t-caption tracking-caps" for="task-project-select">Project</label>
        <select id="task-project-select" name="projectId" class="form-select" data-enhance="custom-select">
      $optionsHtml
        </select>
      </div>
''';
}
