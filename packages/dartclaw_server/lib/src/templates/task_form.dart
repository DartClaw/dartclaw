import 'dart:convert';

/// Returns HTML for the "New Task" dialog element.
///
/// Rendered as a `<dialog>` that can be opened via `showModal()`.
/// Form submission is handled by JS in `app.js`.
String newTaskFormDialogHtml({List<Map<String, String>> goalOptions = const []}) {
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

  return '''
<dialog id="new-task-dialog" class="task-dialog">
  <form id="new-task-form" method="dialog">
    <div class="task-dialog-header">
      <h2>New Task</h2>
      <button type="button" class="btn-close" aria-label="Close" data-task-dialog-close data-icon="x"></button>
    </div>

    <div class="task-dialog-body">
      <div class="form-group">
        <label class="form-label" for="task-title">Title</label>
        <input type="text" id="task-title" name="title" class="form-input" required
               placeholder="Brief task title">
      </div>

      <div class="form-group">
        <label class="form-label" for="task-type-select">Type</label>
        <select id="task-type-select" name="type" class="form-select" required>
          <option value="coding">Coding</option>
          <option value="research">Research</option>
          <option value="writing">Writing</option>
          <option value="analysis">Analysis</option>
          <option value="automation">Automation</option>
          <option value="custom">Custom</option>
        </select>
      </div>

      <div class="form-group">
        <div id="task-type-guidance" class="task-type-guidance">
          <p class="empty-state-text" data-task-type-hint>
            Coding tasks run in isolated git worktrees and produce diffs for review.
          </p>
        </div>
      </div>

      <div class="form-group">
        <label class="form-label" for="task-description" data-task-description-label>Description</label>
        <textarea id="task-description" name="description" class="form-input" required data-task-description-input
                  rows="3" placeholder="What should the agent do?"></textarea>
      </div>

      <div class="form-group">
        <label class="form-label" for="task-goal-select">Goal</label>
        <select id="task-goal-select" name="goalId" class="form-select">
$goalSelectMarkup
        </select>
      </div>

      <div class="form-group">
        <label class="form-label" for="task-acceptance-criteria" data-task-criteria-label>Acceptance Criteria</label>
        <textarea id="task-acceptance-criteria" name="acceptanceCriteria" class="form-input" data-task-criteria-input
                  rows="3" placeholder="How will you know when it's done?"></textarea>
      </div>

      <details class="task-advanced-section">
        <summary class="form-label">Advanced</summary>
        <div class="task-advanced-fields">
          <div class="form-group">
            <label class="form-label" for="task-model">Model Override</label>
            <input type="text" id="task-model" name="model" class="form-input"
                   placeholder="default">
          </div>
          <div class="form-group">
            <label class="form-label" for="task-token-budget">Token Budget</label>
            <input type="number" id="task-token-budget" name="tokenBudget" class="form-input"
                   min="0" placeholder="No limit">
          </div>
        </div>
      </details>

      <div class="form-group form-group-checkbox">
        <input type="checkbox" id="auto-start-checkbox" name="autoStart">
        <label for="auto-start-checkbox">Start immediately</label>
      </div>
    </div>

    <div class="task-dialog-footer">
      <div id="new-task-error" class="form-error"></div>
      <div class="task-dialog-actions">
        <button type="button" class="btn btn-ghost" data-task-dialog-close>Cancel</button>
        <button type="submit" class="btn btn-primary">Create Task</button>
      </div>
    </div>
  </form>
</dialog>
''';
}
