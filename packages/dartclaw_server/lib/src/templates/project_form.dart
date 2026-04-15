/// Returns HTML for the "Add Project" dialog element.
///
/// Rendered as a `<dialog>` that can be opened via `showModal()`.
/// Form submission is handled by JS in `app.js`.
String addProjectDialogHtml() {
  return '''
<dialog id="add-project-dialog" class="task-dialog">
  <form id="add-project-form" method="dialog">
    <div class="task-dialog-header">
      <h2>Add Project</h2>
      <button type="button" class="btn-close" aria-label="Close" data-project-dialog-close data-icon="x"></button>
    </div>

    <div class="task-dialog-body">
      <div class="form-group">
        <label class="form-label" for="project-remote-url">Remote URL</label>
        <input type="text" id="project-remote-url" name="remoteUrl" class="form-input" required
               placeholder="git@github.com:user/repo.git">
      </div>

      <div class="form-group">
        <label class="form-label" for="project-name">Name</label>
        <input type="text" id="project-name" name="name" class="form-input" required
               placeholder="my-project">
      </div>

      <div class="form-group">
        <label class="form-label" for="project-branch">Default Branch</label>
        <input type="text" id="project-branch" name="defaultBranch" class="form-input"
               value="main" placeholder="main">
      </div>

      <div class="form-group">
        <label class="form-label" for="project-creds-ref">Credentials Reference</label>
        <input type="text" id="project-creds-ref" name="credentialsRef" class="form-input"
               placeholder="github-main">
        <small class="form-hint">Optional. Name of a credential defined in dartclaw.yaml.</small>
      </div>

      <div class="form-group">
        <label class="form-label" for="project-pr-strategy">PR Strategy</label>
        <select id="project-pr-strategy" name="prStrategy" class="form-select">
          <option value="githubPr">GitHub PR</option>
          <option value="branchOnly" selected>Branch Only</option>
        </select>
      </div>

      <div class="form-group form-group-checkbox">
        <input type="checkbox" id="project-pr-draft" name="draft" checked>
        <label for="project-pr-draft">Create PRs as draft</label>
      </div>

      <div class="form-group">
        <label class="form-label" for="project-labels">Labels</label>
        <input type="text" id="project-labels" name="labels" class="form-input"
               placeholder="agent, automated">
        <small class="form-hint">Optional. Comma-separated labels to apply to PRs.</small>
      </div>
    </div>

    <div class="task-dialog-footer">
      <div id="add-project-error" class="form-error"></div>
      <div class="task-dialog-actions">
        <button type="button" class="btn btn-ghost" data-project-dialog-close>Cancel</button>
        <button type="submit" class="btn btn-primary">Add Project</button>
      </div>
    </div>
  </form>
</dialog>
''';
}
