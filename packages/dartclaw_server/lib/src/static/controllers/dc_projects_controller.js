import { initCustomSelects, showToast } from './shared.js';

export default class DcProjectsController extends Stimulus.Controller {
  connect() {
    this.handleClick = this.handleClick.bind(this);
    this.handleSubmit = this.handleSubmit.bind(this);
    this.element.addEventListener('click', this.handleClick);
    document.addEventListener('submit', this.handleSubmit, true);
    initCustomSelects(this.element);
  }

  disconnect() {
    this.element.removeEventListener('click', this.handleClick);
    document.removeEventListener('submit', this.handleSubmit, true);
  }

  handleClick(event) {
    if (event.target.closest('[data-project-dialog-open]')) {
      this.openDialog();
      return;
    }
    if (event.target.closest('[data-project-dialog-close]')) {
      this.dialog?.close();
      return;
    }
    const fetchButton = event.target.closest('[data-project-fetch]');
    if (fetchButton) {
      this.fetchProject(fetchButton);
      return;
    }
    const removeButton = event.target.closest('[data-project-remove]');
    if (removeButton) {
      this.removeProject(removeButton);
      return;
    }
    const editButton = event.target.closest('[data-project-edit]');
    if (editButton) {
      this.openEditDialog(editButton);
    }
  }

  handleSubmit(event) {
    if (event.target.id !== 'add-project-form') return;
    event.preventDefault();
    event.stopImmediatePropagation();
    const form = event.target;
    if (form.dataset.editProjectId) {
      this.updateProject(form);
    } else {
      this.createProject(form);
    }
  }

  get dialog() {
    return document.getElementById('add-project-dialog');
  }

  get errorElement() {
    return document.getElementById('add-project-error');
  }

  openDialog() {
    const dialog = this.dialog;
    if (!dialog) return;
    const form = dialog.querySelector('form');
    form?.reset();
    if (form) delete form.dataset.editProjectId;
    dialog.querySelector('h2').textContent = 'Add Project';
    dialog.querySelector('[type="submit"]').textContent = 'Add Project';
    if (this.errorElement) this.errorElement.textContent = '';
    dialog.showModal();
  }

  openEditDialog(button) {
    const dialog = this.dialog;
    const form = dialog?.querySelector('form');
    if (!dialog || !form) return;

    dialog.querySelector('h2').textContent = 'Edit Project';
    dialog.querySelector('[type="submit"]').textContent = 'Save Changes';
    form.dataset.editProjectId = button.dataset.projectEdit;
    if (this.errorElement) this.errorElement.textContent = '';

    this.setValue(form, 'remoteUrl', button.dataset.projectUrl);
    this.setValue(form, 'name', button.dataset.projectName);
    this.setValue(form, 'defaultBranch', button.dataset.projectBranch);
    this.setValue(form, 'credentialsRef', button.dataset.projectCreds);
    this.setValue(form, 'prStrategy', button.dataset.projectStrategy);
    this.setChecked(form, 'draft', button.dataset.projectDraft);
    this.setValue(form, 'labels', button.dataset.projectLabels);
    dialog.showModal();
  }

  setValue(form, name, value) {
    const element = form.querySelector('[name="' + name + '"]');
    if (element) element.value = value || '';
  }

  setChecked(form, name, value) {
    const element = form.querySelector('[name="' + name + '"]');
    if (element) element.checked = value === 'true' || value === true;
  }

  projectPayload(form, { edit = false } = {}) {
    const remoteUrl = form.querySelector('[name="remoteUrl"]')?.value.trim() || '';
    const name = form.querySelector('[name="name"]')?.value.trim() || '';
    const defaultBranch = form.querySelector('[name="defaultBranch"]')?.value.trim() || 'main';
    const credentialsRef = form.querySelector('[name="credentialsRef"]')?.value.trim() || '';
    const prStrategy = form.querySelector('[name="prStrategy"]')?.value || 'branchOnly';
    const draft = form.querySelector('[name="draft"]')?.checked ?? true;
    const labelsRaw = form.querySelector('[name="labels"]')?.value.trim() || '';
    const labels = labelsRaw ? labelsRaw.split(',').map((label) => label.trim()).filter(Boolean) : [];
    const body = { name, defaultBranch, pr: { strategy: prStrategy, draft, labels } };
    if (!edit || remoteUrl) body.remoteUrl = remoteUrl;
    if (credentialsRef) body.credentialsRef = credentialsRef;
    return body;
  }

  async createProject(form) {
    const body = this.projectPayload(form);
    if (!body.remoteUrl || !body.name) {
      if (this.errorElement) this.errorElement.textContent = 'Remote URL and Name are required.';
      return;
    }
    try {
      const response = await fetch('/api/projects', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (response.ok || response.status === 201) {
        this.dialog?.close();
        window.location.reload();
        return;
      }
      const data = await response.json().catch(() => ({}));
      if (this.errorElement) this.errorElement.textContent = data.error?.message || 'Failed to add project';
    } catch (_) {
      if (this.errorElement) this.errorElement.textContent = 'Failed to reach server';
    }
  }

  async updateProject(form) {
    const editProjectId = form.dataset.editProjectId;
    if (!editProjectId) return;
    try {
      const response = await fetch('/api/projects/' + editProjectId, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(this.projectPayload(form, { edit: true })),
      });
      if (response.ok) {
        delete form.dataset.editProjectId;
        this.dialog?.close();
        window.location.reload();
        return;
      }
      const data = await response.json().catch(() => ({}));
      const fallback = response.status === 409 ? 'Cannot edit: active tasks exist on this project' : 'Failed to update project';
      if (this.errorElement) this.errorElement.textContent = data.error?.message || fallback;
    } catch (_) {
      if (this.errorElement) this.errorElement.textContent = 'Failed to reach server';
    }
  }

  async fetchProject(button) {
    const projectId = button.dataset.projectFetch;
    if (!projectId) return;
    button.disabled = true;
    const originalText = button.textContent;
    button.textContent = 'Fetching...';
    try {
      const response = await fetch('/api/projects/' + projectId + '/fetch', { method: 'POST' });
      if (response.ok) {
        window.location.reload();
        return;
      }
      const data = await response.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Fetch failed');
    } catch (_) {
      showToast('error', 'Failed to reach server');
    } finally {
      button.disabled = false;
      button.textContent = originalText;
    }
  }

  async removeProject(button) {
    const projectId = button.dataset.projectRemove;
    const projectName = button.dataset.projectName || projectId;
    if (!projectId) return;
    if (!window.confirm('Remove project \'' + projectName + '\'? Running tasks will be cancelled.')) return;
    try {
      const response = await fetch('/api/projects/' + projectId, { method: 'DELETE' });
      if (response.ok || response.status === 204) {
        window.location.reload();
        return;
      }
      const data = await response.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Failed to remove project');
    } catch (_) {
      showToast('error', 'Failed to reach server');
    }
  }
}
