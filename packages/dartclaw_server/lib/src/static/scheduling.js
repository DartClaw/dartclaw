// scheduling.js - DartClaw scheduling page logic
'use strict';

// === Scheduling: Job Management ===

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

  const url = isEdit ? '/api/scheduling/jobs/' + encodeURIComponent(editName) : '/api/scheduling/jobs';
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
    method: method,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
    .then(function (r) { return r.json().then(function (data) { return { ok: r.ok, data: data }; }); })
    .then(function (result) {
      if (result.ok) {
        toggleJobForm();
        htmx.ajax('GET', '/scheduling', { target: '#main-content', swap: 'outerHTML' });
      } else {
        var msg = (result.data && result.data.error && result.data.error.message) || 'Failed to save job';
        showToast('error', msg);
      }
    })
    .catch(function () { showToast('error', 'Network error — could not save job'); })
    .finally(function () {
      saveBtn.textContent = 'Save Job';
      saveBtn.disabled = false;
    });
}

function editJob(btn, jobName) {
  var row = btn.closest('tr');
  var cells = row.querySelectorAll('td');

  var form = document.getElementById('job-form');
  if (!form) return;
  form.querySelector('.form-title').textContent = 'Edit Job: ' + jobName;
  form.querySelector('#job-name').value = jobName;
  form.querySelector('#job-name').disabled = true;
  form.querySelector('#job-schedule').value = cells[1] ? (cells[1].querySelector('.cron-expr')?.textContent || '') : '';
  form.querySelector('#job-prompt').value = '';
  form.querySelector('#job-prompt').placeholder = 'Leave empty to keep current prompt';

  var saveBtn = form.querySelector('.form-actions .btn-primary');
  saveBtn.textContent = 'Update Job';
  saveBtn.dataset.action = 'submit-job-form';
  saveBtn.dataset.editName = jobName;

  form.style.display = 'block';
  form.querySelector('#job-schedule').focus();
  updateCronPreview(form.querySelector('#job-schedule').value);
}

function confirmDeleteJob(btn, jobName) {
  var row = btn.closest('tr');
  var confirmRow = document.createElement('tr');
  confirmRow.className = 'delete-confirm-row';

  var td = document.createElement('td');
  td.colSpan = 5;

  var bar = document.createElement('div');
  bar.className = 'delete-confirm-bar';

  var msg = document.createElement('span');
  msg.className = 'confirm-msg';
  msg.textContent = "Delete '" + jobName + "'?";

  var confirmBtn = document.createElement('button');
  confirmBtn.className = 'btn btn-danger-fill btn-sm';
  confirmBtn.dataset.action = 'execute-delete-job';
  confirmBtn.dataset.jobName = jobName;
  confirmBtn.textContent = 'Confirm Delete';

  var cancelBtn = document.createElement('button');
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

  fetch('/api/scheduling/jobs/' + encodeURIComponent(jobName), { method: 'DELETE' })
    .then(function (r) { return r.json().then(function (data) { return { ok: r.ok, data: data }; }); })
    .then(function (result) {
      if (result.ok) {
        htmx.ajax('GET', '/scheduling', { target: '#main-content', swap: 'outerHTML' });
      } else {
        var msg = (result.data && result.data.error && result.data.error.message) || 'Failed to delete job';
        showToast('error', msg);
        cancelDeleteJob(btn);
      }
    })
    .catch(function () {
      showToast('error', 'Network error');
      cancelDeleteJob(btn);
    });
}

function cancelDeleteJob(btn) {
  var confirmRow = btn.closest('.delete-confirm-row');
  if (confirmRow) {
    var prevRow = confirmRow.previousElementSibling;
    if (prevRow) prevRow.style.display = '';
    confirmRow.remove();
  }
}
