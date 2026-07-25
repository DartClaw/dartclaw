export default class DcSchedulingController extends Stimulus.Controller {
  connect() {
    this.updateJobCronPreview();
    this.updateTaskCronPreview();
  }

  get apiQs() {
    return window.dartclaw?.shell?.apiQs?.() || '';
  }

  get ui() {
    return window.dartclaw?.ui || {};
  }

  refreshSchedulingPage() {
    htmx.ajax('GET', '/scheduling' + this.apiQs, {
      target: '#main-content',
      select: '#main-content',
      swap: 'outerHTML',
    });
  }

  toggleJobForm() {
    const form = document.getElementById('job-form');
    if (!form) return;

    const visible = !form.hidden;
    form.hidden = visible;
    if (visible) return;

    form.querySelector('.form-title').textContent = 'Add New Job';
    form.querySelector('#job-name').value = '';
    form.querySelector('#job-name').disabled = false;
    form.querySelector('#job-schedule').value = '';
    form.querySelector('#job-prompt').value = '';
    form.querySelector('#job-prompt').placeholder = 'Describe the task for the agent...';
    form.querySelector('input[name="delivery"][value="announce"]').checked = true;
    form.querySelector('#cron-preview').textContent = '';
    const saveBtn = form.querySelector('.form-actions .btn-primary');
    saveBtn.textContent = 'Save Job';
    delete saveBtn.dataset.editName;
    form.querySelector('#job-name').focus();
  }

  updateJobCronPreview(event) {
    const input = event?.currentTarget || document.getElementById('job-schedule');
    const el = document.getElementById('cron-preview');
    if (!el) return;
    el.textContent = this.describeCron(input?.value || '');
  }

  updateTaskCronPreview(event) {
    const input = event?.currentTarget || document.getElementById('task-schedule');
    const el = document.getElementById('task-cron-preview');
    if (!el) return;
    el.textContent = this.describeCron(input?.value || '');
  }

  describeCron(expr) {
    const parts = expr.trim().split(/\s+/);
    if (parts.length !== 5) return '';
    const [min, hour, dom, mon, dow] = parts;

    if (expr.trim() === '* * * * *') return 'Every minute';

    const minInterval = min.match(/^\*\/(\d+)$/);
    if (minInterval && hour === '*' && dom === '*' && mon === '*' && dow === '*') {
      return 'Every ' + minInterval[1] + ' minutes';
    }

    const hourInterval = hour.match(/^\*\/(\d+)$/);
    if (min === '0' && hourInterval && dom === '*' && mon === '*' && dow === '*') {
      return 'Every ' + hourInterval[1] + ' hours';
    }

    if (min === '0' && hour === '*' && dom === '*' && mon === '*' && dow === '*') {
      return 'Every hour';
    }

    if (/^\d+$/.test(min) && /^\d+$/.test(hour) && dom === '*' && mon === '*' && dow === '*') {
      return 'Daily at ' + this.formatTime(+hour, +min);
    }

    const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    if (/^\d+$/.test(min) && /^\d+$/.test(hour) && dom === '*' && mon === '*' && /^\d$/.test(dow)) {
      return 'Weekly on ' + (dayNames[+dow] || dow) + ' at ' + this.formatTime(+hour, +min);
    }

    if (/^\d+$/.test(min) && /^\d+$/.test(hour) && /^\d+$/.test(dom) && mon === '*' && dow === '*') {
      const suffix = dom === '1' ? 'st' : dom === '2' ? 'nd' : dom === '3' ? 'rd' : 'th';
      return 'Monthly on the ' + dom + suffix + ' at ' + this.formatTime(+hour, +min);
    }

    return '';
  }

  formatTime(h, m) {
    const ampm = h >= 12 ? 'PM' : 'AM';
    const h12 = h % 12 || 12;
    return h12 + ':' + String(m).padStart(2, '0') + ' ' + ampm;
  }

  async submitJobForm(event) {
    const form = document.getElementById('job-form');
    if (!form) return;

    const button = event?.currentTarget;
    const editName = button?.dataset?.editName;
    const name = form.querySelector('#job-name').value.trim();
    const schedule = form.querySelector('#job-schedule').value.trim();
    const prompt = form.querySelector('#job-prompt').value.trim();
    const delivery = form.querySelector('input[name="delivery"]:checked')?.value || 'none';

    const isEdit = !!editName;
    if (!isEdit && (!name || !schedule || !prompt)) return;
    if (isEdit && !schedule) return;

    const url = isEdit
      ? '/api/scheduling/jobs/' + encodeURIComponent(editName) + this.apiQs
      : '/api/scheduling/jobs' + this.apiQs;
    const method = isEdit ? 'PUT' : 'POST';

    const body = { schedule, delivery };
    if (!isEdit) {
      body.name = name;
      body.prompt = prompt;
    }
    if (prompt) body.prompt = prompt;

    const saveBtn = form.querySelector('.form-actions .btn-primary');
    saveBtn.textContent = 'Saving...';
    saveBtn.disabled = true;

    try {
      const response = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await response.json().catch(() => ({}));
      if (response.ok) {
        this.toggleJobForm();
        this.refreshSchedulingPage();
      } else {
        this.showToast('error', data.error?.message || 'Failed to save job');
      }
    } catch (_) {
      this.showToast('error', 'Network error - could not save job');
    } finally {
      saveBtn.textContent = isEdit ? 'Update Job' : 'Save Job';
      saveBtn.disabled = false;
    }
  }

  editJob(event) {
    const button = event?.currentTarget;
    const jobName = button?.dataset?.jobName;
    const row = button?.closest('tr');
    const cells = row?.querySelectorAll('td') || [];
    const form = document.getElementById('job-form');
    if (!form || !jobName) return;

    form.querySelector('.form-title').textContent = 'Edit Job: ' + jobName;
    form.querySelector('#job-name').value = jobName;
    form.querySelector('#job-name').disabled = true;
    form.querySelector('#job-schedule').value = cells[1]?.querySelector('.cron-expr')?.textContent || '';
    form.querySelector('#job-prompt').value = '';
    form.querySelector('#job-prompt').placeholder = 'Leave empty to keep current prompt';

    const saveBtn = form.querySelector('.form-actions .btn-primary');
    saveBtn.textContent = 'Update Job';
    saveBtn.dataset.editName = jobName;

    form.hidden = false;
    form.querySelector('#job-schedule').focus();
    this.updateJobCronPreview();
  }

  confirmDeleteJob(event) {
    const button = event?.currentTarget;
    const jobName = button?.dataset?.jobName;
    const row = button?.closest('tr');
    if (!row || !jobName) return;

    const confirmRow = document.createElement('tr');
    confirmRow.className = 'delete-confirm-row';

    const td = document.createElement('td');
    td.colSpan = 5;

    const bar = document.createElement('div');
    bar.className = 'delete-confirm-bar';

    const msg = document.createElement('span');
    msg.className = 'confirm-msg';
    msg.textContent = "Delete '" + jobName + "'?";

    const confirmBtn = document.createElement('button');
    confirmBtn.className = 'btn btn-danger-fill btn-sm';
    confirmBtn.dataset.action = 'click->dc-scheduling#executeDeleteJob';
    confirmBtn.dataset.jobName = jobName;
    confirmBtn.textContent = 'Confirm Delete';

    const cancelBtn = document.createElement('button');
    cancelBtn.className = 'btn btn-ghost btn-sm';
    cancelBtn.dataset.action = 'click->dc-scheduling#cancelDeleteJob';
    cancelBtn.textContent = 'Cancel';

    bar.append(msg, confirmBtn, cancelBtn);
    td.appendChild(bar);
    confirmRow.appendChild(td);
    row.parentNode.insertBefore(confirmRow, row.nextSibling);
    row.style.display = 'none';
  }

  async executeDeleteJob(event) {
    const button = event?.currentTarget;
    const jobName = button?.dataset?.jobName;
    if (!button || !jobName) return;

    button.textContent = 'Deleting...';
    button.disabled = true;

    try {
      const response = await fetch('/api/scheduling/jobs/' + encodeURIComponent(jobName) + this.apiQs, {
        method: 'DELETE',
      });
      const data = await response.json().catch(() => ({}));
      if (response.ok) {
        this.refreshSchedulingPage();
      } else {
        this.showToast('error', data.error?.message || 'Failed to delete job');
        this.cancelDeleteJob(event);
      }
    } catch (_) {
      this.showToast('error', 'Network error');
      this.cancelDeleteJob(event);
    }
  }

  cancelDeleteJob(event) {
    const confirmRow = event?.currentTarget?.closest('.delete-confirm-row');
    if (!confirmRow) return;

    const prevRow = confirmRow.previousElementSibling;
    if (prevRow) prevRow.style.display = '';
    confirmRow.remove();
  }

  toggleTaskForm() {
    const form = document.getElementById('task-form');
    if (!form) return;

    const visible = !form.hidden;
    form.hidden = visible;
    if (!visible) {
      this.resetTaskForm();
    }
  }

  resetTaskForm() {
    const titleEl = document.getElementById('task-form-title');
    if (titleEl) titleEl.textContent = 'Add Scheduled Task';
    document.getElementById('task-edit-id').value = '';
    document.getElementById('task-id').value = '';
    document.getElementById('task-id').disabled = false;
    document.getElementById('task-schedule').value = '';
    document.getElementById('task-title').value = '';
    document.getElementById('task-description').value = '';
    document.getElementById('task-type').selectedIndex = 0;
    document.getElementById('task-acceptance').value = '';
    document.getElementById('task-enabled').checked = true;
    this.updateTaskCronPreview();
  }

  async submitTaskForm() {
    const editId = document.getElementById('task-edit-id')?.value?.trim();
    const id = document.getElementById('task-id')?.value?.trim();
    const schedule = document.getElementById('task-schedule')?.value?.trim();
    const title = document.getElementById('task-title')?.value?.trim();
    const description = document.getElementById('task-description')?.value?.trim();
    const type = document.getElementById('task-type')?.value;
    const acceptance = document.getElementById('task-acceptance')?.value?.trim();
    const enabled = document.getElementById('task-enabled')?.checked ?? true;

    if (!id || !schedule || !title || !description || !type) {
      this.showToast('error', 'ID, schedule, title, description, and type are required');
      return;
    }

    const body = { id, schedule, title, description, type, enabled };
    if (acceptance) body.acceptanceCriteria = acceptance;

    try {
      const isEdit = editId && editId.length > 0;
      const url = isEdit
        ? '/api/scheduling/tasks/' + encodeURIComponent(editId) + this.apiQs
        : '/api/scheduling/tasks' + this.apiQs;
      const method = isEdit ? 'PUT' : 'POST';

      const response = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (response.ok || response.status === 201) {
        this.showToast('success', (isEdit ? 'Task updated' : 'Task created') + ' - restart required');
        this.refreshSchedulingPage();
      } else {
        const data = await response.json().catch(() => ({}));
        this.showToast('error', data.error?.message || 'Failed to save scheduled task');
      }
    } catch (_) {
      this.showToast('error', 'Failed to reach server');
    }
  }

  async toggleScheduledTask(event) {
    const taskId = event?.currentTarget?.dataset?.taskId;
    if (!taskId) return;

    try {
      const configResp = await fetch('/api/config' + this.apiQs);
      if (!configResp.ok) {
        this.showToast('error', 'Failed to read config');
        return;
      }
      const config = await configResp.json();
      const jobs = config.scheduling?.jobs || [];
      const job = jobs.find((item) => item.type === 'task' && item.id === taskId);
      if (!job) {
        this.showToast('error', 'Task not found');
        return;
      }

      const response = await fetch('/api/scheduling/tasks/' + encodeURIComponent(taskId) + this.apiQs, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: !job.enabled }),
      });
      if (response.ok) {
        this.showToast('success', 'Task ' + (!job.enabled ? 'enabled' : 'disabled') + ' - restart required');
        this.refreshSchedulingPage();
      } else {
        const data = await response.json().catch(() => ({}));
        this.showToast('error', data.error?.message || 'Failed to toggle task');
      }
    } catch (_) {
      this.showToast('error', 'Failed to reach server');
    }
  }

  async editScheduledTask(event) {
    const taskId = event?.currentTarget?.dataset?.taskId;
    if (!taskId) return;

    try {
      const configResp = await fetch('/api/config' + this.apiQs);
      if (!configResp.ok) {
        this.showToast('error', 'Failed to read config');
        return;
      }
      const config = await configResp.json();
      const jobs = config.scheduling?.jobs || [];
      const job = jobs.find((item) => item.type === 'task' && item.id === taskId);
      if (!job) {
        this.showToast('error', 'Task not found in config');
        return;
      }
      const taskDef = job.task || {};

      const form = document.getElementById('task-form');
      if (form) form.hidden = false;
      const titleEl = document.getElementById('task-form-title');
      if (titleEl) titleEl.textContent = 'Edit Scheduled Task';
      document.getElementById('task-edit-id').value = taskId;
      document.getElementById('task-id').value = job.id;
      document.getElementById('task-id').disabled = true;
      document.getElementById('task-schedule').value = job.schedule || '';
      document.getElementById('task-title').value = taskDef.title || '';
      document.getElementById('task-description').value = taskDef.description || '';

      const typeSelect = document.getElementById('task-type');
      const taskType = taskDef.type || taskDef.task_type;
      if (typeSelect && taskType) {
        for (let index = 0; index < typeSelect.options.length; index += 1) {
          if (typeSelect.options[index].value === taskType) {
            typeSelect.selectedIndex = index;
            break;
          }
        }
      }
      document.getElementById('task-acceptance').value = taskDef.acceptance_criteria || '';
      document.getElementById('task-enabled').checked = job.enabled !== false;
      this.updateTaskCronPreview();
    } catch (_) {
      this.showToast('error', 'Failed to reach server');
    }
  }

  async deleteScheduledTask(event) {
    const taskId = event?.currentTarget?.dataset?.taskId;
    if (!taskId || !window.confirm('Delete scheduled task "' + taskId + '"?')) return;

    try {
      const response = await fetch('/api/scheduling/tasks/' + encodeURIComponent(taskId) + this.apiQs, {
        method: 'DELETE',
      });
      if (response.ok) {
        this.showToast('success', 'Scheduled task deleted - restart required');
        this.refreshSchedulingPage();
      } else {
        const data = await response.json().catch(() => ({}));
        this.showToast('error', data.error?.message || 'Failed to delete scheduled task');
      }
    } catch (_) {
      this.showToast('error', 'Failed to reach server');
    }
  }

  showToast(type, message) {
    if (typeof this.ui.showToast === 'function') {
      this.ui.showToast(type, message);
    }
  }
}
