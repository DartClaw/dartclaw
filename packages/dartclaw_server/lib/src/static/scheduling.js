(() => {
  'use strict';

  const dartclaw = window.dartclaw = window.dartclaw || {};
  dartclaw.ui = dartclaw.ui || {};
  dartclaw.shell = dartclaw.shell || {};
  dartclaw.pages = dartclaw.pages || {};

  const ui = dartclaw.ui;
  const shell = dartclaw.shell;
  const schedulingPage = dartclaw.pages.scheduling = dartclaw.pages.scheduling || {};

  function apiQs() {
    return typeof shell.apiQs === 'function' ? shell.apiQs() : '';
  }

  function refreshSchedulingPage() {
    htmx.ajax('GET', '/scheduling' + apiQs(), {
      target: '#main-content',
      select: '#main-content',
      swap: 'outerHTML',
    });
  }

  function toggleJobForm() {
    const form = document.getElementById('job-form');
    if (!form) return;
    const visible = form.style.display !== 'none';
    form.style.display = visible ? 'none' : 'block';
    if (!visible) {
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
  }

  function updateCronPreview(expr) {
    const el = document.getElementById('cron-preview');
    if (!el) return;
    el.textContent = describeCron(expr);
  }

  function updateTaskCronPreview(expr) {
    const el = document.getElementById('task-cron-preview');
    if (!el) return;
    el.textContent = describeCron(expr);
  }

  function describeCron(expr) {
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
      return 'Daily at ' + formatTime(+hour, +min);
    }

    const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    if (/^\d+$/.test(min) && /^\d+$/.test(hour) && dom === '*' && mon === '*' && /^\d$/.test(dow)) {
      return 'Weekly on ' + (dayNames[+dow] || dow) + ' at ' + formatTime(+hour, +min);
    }

    if (/^\d+$/.test(min) && /^\d+$/.test(hour) && /^\d+$/.test(dom) && mon === '*' && dow === '*') {
      var suffix = dom === '1' ? 'st' : dom === '2' ? 'nd' : dom === '3' ? 'rd' : 'th';
      return 'Monthly on the ' + dom + suffix + ' at ' + formatTime(+hour, +min);
    }

    return '';
  }

  function formatTime(h, m) {
    var ampm = h >= 12 ? 'PM' : 'AM';
    var h12 = h % 12 || 12;
    return h12 + ':' + String(m).padStart(2, '0') + ' ' + ampm;
  }

  function submitJobForm(editName) {
    const form = document.getElementById('job-form');
    if (!form) return;
    const name = form.querySelector('#job-name').value.trim();
    const schedule = form.querySelector('#job-schedule').value.trim();
    const prompt = form.querySelector('#job-prompt').value.trim();
    const delivery = form.querySelector('input[name="delivery"]:checked')?.value || 'none';

    const isEdit = !!editName;
    if (!isEdit && (!name || !schedule || !prompt)) return;
    if (isEdit && !schedule) return;

    const url = isEdit
      ? '/api/scheduling/jobs/' + encodeURIComponent(editName) + apiQs()
      : '/api/scheduling/jobs' + apiQs();
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

    fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
      .then((response) => response.json().then((data) => ({ ok: response.ok, data })))
      .then((result) => {
        if (result.ok) {
          toggleJobForm();
          refreshSchedulingPage();
        } else {
          const msg = (result.data && result.data.error && result.data.error.message) || 'Failed to save job';
          ui.showToast('error', msg);
        }
      })
      .catch(() => {
        ui.showToast('error', 'Network error — could not save job');
      })
      .finally(() => {
        saveBtn.textContent = 'Save Job';
        saveBtn.disabled = false;
      });
  }

  function editJob(btn, jobName) {
    const row = btn.closest('tr');
    const cells = row.querySelectorAll('td');

    const form = document.getElementById('job-form');
    if (!form) return;
    form.querySelector('.form-title').textContent = 'Edit Job: ' + jobName;
    form.querySelector('#job-name').value = jobName;
    form.querySelector('#job-name').disabled = true;
    form.querySelector('#job-schedule').value =
      cells[1] ? (cells[1].querySelector('.cron-expr')?.textContent || '') : '';
    form.querySelector('#job-prompt').value = '';
    form.querySelector('#job-prompt').placeholder = 'Leave empty to keep current prompt';

    const saveBtn = form.querySelector('.form-actions .btn-primary');
    saveBtn.textContent = 'Update Job';
    saveBtn.dataset.action = 'submit-job-form';
    saveBtn.dataset.editName = jobName;

    form.style.display = 'block';
    form.querySelector('#job-schedule').focus();
    updateCronPreview(form.querySelector('#job-schedule').value);
  }

  function confirmDeleteJob(btn, jobName) {
    const row = btn.closest('tr');
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
    confirmBtn.dataset.action = 'execute-delete-job';
    confirmBtn.dataset.jobName = jobName;
    confirmBtn.textContent = 'Confirm Delete';

    const cancelBtn = document.createElement('button');
    cancelBtn.className = 'btn btn-ghost btn-sm';
    cancelBtn.dataset.action = 'cancel-delete-job';
    cancelBtn.textContent = 'Cancel';

    bar.append(msg, confirmBtn, cancelBtn);
    td.appendChild(bar);
    confirmRow.appendChild(td);
    row.parentNode.insertBefore(confirmRow, row.nextSibling);
    row.style.display = 'none';
  }

  function executeDeleteJob(jobName, btn) {
    btn.textContent = 'Deleting...';
    btn.disabled = true;

    fetch('/api/scheduling/jobs/' + encodeURIComponent(jobName) + apiQs(), { method: 'DELETE' })
      .then((response) => response.json().then((data) => ({ ok: response.ok, data })))
      .then((result) => {
        if (result.ok) {
          refreshSchedulingPage();
        } else {
          const msg = (result.data && result.data.error && result.data.error.message) || 'Failed to delete job';
          ui.showToast('error', msg);
          cancelDeleteJob(btn);
        }
      })
      .catch(() => {
        ui.showToast('error', 'Network error');
        cancelDeleteJob(btn);
      });
  }

  function cancelDeleteJob(btn) {
    const confirmRow = btn.closest('.delete-confirm-row');
    if (confirmRow) {
      const prevRow = confirmRow.previousElementSibling;
      if (prevRow) prevRow.style.display = '';
      confirmRow.remove();
    }
  }

  function toggleTaskForm() {
    const form = document.getElementById('task-form');
    if (!form) return;
    const visible = form.style.display !== 'none';
    form.style.display = visible ? 'none' : '';
    if (!visible) {
      resetTaskForm();
    }
  }

  function resetTaskForm() {
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
    updateTaskCronPreview('');
  }

  async function submitTaskForm() {
    const editId = document.getElementById('task-edit-id')?.value?.trim();
    const id = document.getElementById('task-id')?.value?.trim();
    const schedule = document.getElementById('task-schedule')?.value?.trim();
    const title = document.getElementById('task-title')?.value?.trim();
    const description = document.getElementById('task-description')?.value?.trim();
    const type = document.getElementById('task-type')?.value;
    const acceptance = document.getElementById('task-acceptance')?.value?.trim();
    const enabled = document.getElementById('task-enabled')?.checked ?? true;

    if (!id || !schedule || !title || !description || !type) {
      ui.showToast('error', 'ID, schedule, title, description, and type are required');
      return;
    }

    const body = { id, schedule, title, description, type, enabled };
    if (acceptance) body.acceptanceCriteria = acceptance;

    try {
      const isEdit = editId && editId.length > 0;
      const url = isEdit
        ? '/api/scheduling/tasks/' + encodeURIComponent(editId) + apiQs()
        : '/api/scheduling/tasks' + apiQs();
      const method = isEdit ? 'PUT' : 'POST';

      const response = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (response.ok || response.status === 201) {
        ui.showToast('success', (isEdit ? 'Task updated' : 'Task created') + ' — restart required');
        refreshSchedulingPage();
      } else {
        const data = await response.json().catch(() => ({}));
        ui.showToast('error', data.error?.message || 'Failed to save scheduled task');
      }
    } catch (_) {
      ui.showToast('error', 'Failed to reach server');
    }
  }

  async function toggleScheduledTask(taskId) {
    try {
      const configResp = await fetch('/api/config' + apiQs());
      if (!configResp.ok) {
        ui.showToast('error', 'Failed to read config');
        return;
      }
      const config = await configResp.json();
      const jobs = config.scheduling?.jobs || [];
      const job = jobs.find((item) => item.type === 'task' && item.id === taskId);
      if (!job) {
        ui.showToast('error', 'Task not found');
        return;
      }

      const response = await fetch('/api/scheduling/tasks/' + encodeURIComponent(taskId) + apiQs(), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: !job.enabled }),
      });
      if (response.ok) {
        ui.showToast('success', 'Task ' + (!job.enabled ? 'enabled' : 'disabled') + ' — restart required');
        refreshSchedulingPage();
      } else {
        const data = await response.json().catch(() => ({}));
        ui.showToast('error', data.error?.message || 'Failed to toggle task');
      }
    } catch (_) {
      ui.showToast('error', 'Failed to reach server');
    }
  }

  async function editScheduledTask(taskId) {
    try {
      const configResp = await fetch('/api/config' + apiQs());
      if (!configResp.ok) {
        ui.showToast('error', 'Failed to read config');
        return;
      }
      const config = await configResp.json();
      const jobs = config.scheduling?.jobs || [];
      const job = jobs.find((item) => item.type === 'task' && item.id === taskId);
      if (!job) {
        ui.showToast('error', 'Task not found in config');
        return;
      }
      const taskDef = job.task || {};

      const form = document.getElementById('task-form');
      if (form) form.style.display = '';
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
        for (var i = 0; i < typeSelect.options.length; i++) {
          if (typeSelect.options[i].value === taskType) {
            typeSelect.selectedIndex = i;
            break;
          }
        }
      }
      document.getElementById('task-acceptance').value = taskDef.acceptance_criteria || '';
      document.getElementById('task-enabled').checked = job.enabled !== false;
      updateTaskCronPreview(job.schedule || '');
    } catch (_) {
      ui.showToast('error', 'Failed to reach server');
    }
  }

  async function deleteScheduledTask(taskId) {
    try {
      const response = await fetch('/api/scheduling/tasks/' + encodeURIComponent(taskId) + apiQs(), {
        method: 'DELETE',
      });
      if (response.ok) {
        ui.showToast('success', 'Scheduled task deleted — restart required');
        refreshSchedulingPage();
      } else {
        const data = await response.json().catch(() => ({}));
        ui.showToast('error', data.error?.message || 'Failed to delete scheduled task');
      }
    } catch (_) {
      ui.showToast('error', 'Failed to reach server');
    }
  }

  function initSchedulingPage() {
    updateCronPreview((document.getElementById('job-schedule') || {}).value || '');
    updateTaskCronPreview((document.getElementById('task-schedule') || {}).value || '');
  }

  schedulingPage.confirmDeleteJob = confirmDeleteJob;
  schedulingPage.deleteScheduledTask = deleteScheduledTask;
  schedulingPage.editJob = editJob;
  schedulingPage.editScheduledTask = editScheduledTask;
  schedulingPage.executeDeleteJob = executeDeleteJob;
  schedulingPage.cancelDeleteJob = cancelDeleteJob;
  schedulingPage.submitJobForm = submitJobForm;
  schedulingPage.submitTaskForm = submitTaskForm;
  schedulingPage.toggleJobForm = toggleJobForm;
  schedulingPage.toggleScheduledTask = toggleScheduledTask;
  schedulingPage.toggleTaskForm = toggleTaskForm;
  schedulingPage.updateCronPreview = updateCronPreview;
  schedulingPage.updateTaskCronPreview = updateTaskCronPreview;
  schedulingPage.onLoad = initSchedulingPage;
  schedulingPage.onAfterSwap = initSchedulingPage;
  schedulingPage.onHistoryRestore = initSchedulingPage;
})();
