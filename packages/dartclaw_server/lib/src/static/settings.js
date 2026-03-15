// settings.js - DartClaw settings page logic
'use strict';

// === Settings tab navigation (show/hide panels) ===

document.addEventListener('click', (event) => {
  const tab = event.target.closest('.settings-tab');
  if (!tab) return;
  event.preventDefault();

  const targetId = tab.getAttribute('href')?.replace('#', '');
  if (!targetId) return;

  activateSettingsTab(targetId);
  history.replaceState(null, '', '#' + targetId);
});

function activateSettingsTab(tabId) {
  // Update active tab
  document.querySelectorAll('.settings-tab').forEach((t) => {
    t.classList.toggle('active', t.getAttribute('href') === '#' + tabId);
  });

  // Show/hide cards by data-tab
  const grid = document.querySelector('.settings-grid');
  if (!grid) return;

  grid.querySelectorAll('[data-tab]').forEach((card) => {
    card.style.display = card.dataset.tab === tabId ? '' : 'none';
  });

  // Scroll main content to top so the tab content appears right below tabs
  const main = document.querySelector('.page-content');
  if (main) main.scrollTop = 0;
}

// === Scope display labels ===

var scopeDisplayLabels = {
  'sessions.dm_scope': {
    'shared': 'Shared (all DMs in one session)',
    'per-contact': 'Per Contact (one session per sender)',
    'per-channel-contact': 'Per Channel + Contact',
  },
  'sessions.group_scope': {
    'shared': 'Shared (all members in one session)',
    'per-member': 'Per Member (one session per member)',
  },
};

// === Settings Form ===

var settingsInitialConfig = null;

function getNestedValue(obj, path) {
  var parts = path.split('.');
  var current = obj;
  for (var i = 0; i < parts.length; i++) {
    if (current == null) return undefined;
    var key = parts[i];
    if (key in current) {
      current = current[key];
    } else {
      // Try camelCase conversion: foo_bar -> fooBar
      var camel = key.replace(/_([a-z])/g, function (_, c) { return c.toUpperCase(); });
      if (camel in current) {
        current = current[camel];
      } else {
        return undefined;
      }
    }
  }
  return current;
}

function fieldToJsonPath(yamlPath) {
  return yamlPath.split('.').map(function (part) {
    return part.replace(/_([a-z])/g, function (_, c) { return c.toUpperCase(); });
  }).join('.');
}

function getFieldInput(group) {
  return group.querySelector('input, select');
}

function getFieldValue(input) {
  if (!input) return undefined;
  if (input.type === 'checkbox') return input.checked;
  if (input.type === 'number') {
    var val = input.value.trim();
    return val === '' ? null : Number(val);
  }
  return input.value;
}

function setFieldValue(input, value) {
  if (!input) return;
  if (input.type === 'checkbox') {
    input.checked = Boolean(value);
  } else {
    input.value = value != null ? String(value) : '';
  }
}

function populateSettingsForm(config, meta) {
  var groups = document.querySelectorAll('.settings-form [data-field]');
  groups.forEach(function (group) {
    var field = group.dataset.field;
    var input = getFieldInput(group);
    if (!input) return;

    var jsonPath = fieldToJsonPath(field);
    var value = getNestedValue(config, jsonPath);
    setFieldValue(input, value);

    // Populate select options from meta
    var metaField = meta && meta.fields ? meta.fields[field] : null;
    if (input.tagName === 'SELECT' && metaField && metaField.allowedValues) {
      input.innerHTML = '';
      var labels = scopeDisplayLabels[field];
      metaField.allowedValues.forEach(function (v) {
        var opt = document.createElement('option');
        opt.value = v;
        opt.textContent = (labels && labels[v]) || v;
        if (v === String(value)) opt.selected = true;
        input.appendChild(opt);
      });
    }

    // Set number constraints from meta
    if (input.type === 'number' && metaField) {
      if (metaField.min != null) input.min = metaField.min;
      if (metaField.max != null) input.max = metaField.max;
    }

    input.disabled = false;
    input.placeholder = '';
  });
}

function checkRestartBanner(config) {
  var banner = document.getElementById('restart-banner');
  if (!banner) return;

  var meta = config._meta || {};
  if (meta.restartPending && meta.pendingFields && meta.pendingFields.length > 0) {
    if (!dartclaw._restartBannerDismissed) {
      var fieldsEl = document.getElementById('restart-banner-fields');
      if (fieldsEl) fieldsEl.textContent = meta.pendingFields.join(', ');
      banner.style.display = '';
    }
  } else {
    banner.style.display = 'none';
  }
}

function updateFormDirtyState(form) {
  if (!settingsInitialConfig) return;

  var groups = form.querySelectorAll('[data-field]');
  var dirty = false;

  groups.forEach(function (group) {
    if (group.classList.contains('form-group-toggle')) return;

    var field = group.dataset.field;
    var input = getFieldInput(group);
    if (!input) return;

    var jsonPath = fieldToJsonPath(field);
    var initial = getNestedValue(settingsInitialConfig, jsonPath);
    var current = getFieldValue(input);

    if (initial == null) initial = null;
    if (current == null) current = null;

    if (current !== initial) dirty = true;
  });

}

function clearFormErrors(form) {
  form.querySelectorAll('.form-error').forEach(function (el) { el.textContent = ''; });
  form.querySelectorAll('.form-input.error').forEach(function (el) { el.classList.remove('error'); });
}

function handleToggleChange(field, value) {
  var body = {};
  body[field] = value;

  fetch('/api/config', {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
    .then(function (res) {
      if (!res.ok) return res.json().then(function (d) { throw d; });
      return res.json();
    })
    .then(function () {
      if (settingsInitialConfig) {
        var jsonPath = fieldToJsonPath(field);
        var parts = jsonPath.split('.');
        var obj = settingsInitialConfig;
        for (var i = 0; i < parts.length - 1; i++) {
          if (!obj[parts[i]]) obj[parts[i]] = {};
          obj = obj[parts[i]];
        }
        obj[parts[parts.length - 1]] = value;
      }
      showToast('success', 'Applied');
    })
    .catch(function (err) {
      var group = document.querySelector('[data-field="' + field + '"]');
      if (group) {
        var input = getFieldInput(group);
        if (input) input.checked = !value;
      }
      var msg = (err && err.error && err.error.message) || 'Failed to apply';
      showToast('error', msg);
    });
}

function handleFormSave(form) {
  if (!settingsInitialConfig) return;

  var changes = {};
  var groups = form.querySelectorAll('[data-field]');

  groups.forEach(function (group) {
    if (group.classList.contains('form-group-toggle')) return;

    var field = group.dataset.field;
    var input = getFieldInput(group);
    if (!input) return;

    var jsonPath = fieldToJsonPath(field);
    var initial = getNestedValue(settingsInitialConfig, jsonPath);
    var current = getFieldValue(input);

    if (initial == null) initial = null;
    if (current == null) current = null;

    if (current !== initial) {
      changes[field] = current;
    }
  });

  if (Object.keys(changes).length === 0) {
    showToast('info', 'No changes');
    return;
  }

  clearFormErrors(form);

  var saveBtn = form.querySelector('.form-actions .btn-primary');
  if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Saving...'; }

  fetch('/api/config', {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(changes),
  })
    .then(function (res) {
      return res.json().then(function (data) { return { ok: res.ok, status: res.status, data: data }; });
    })
    .then(function (result) {
      if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save'; }

      if (!result.ok) {
        var errors = (result.data && result.data.errors) || [];
        if (Array.isArray(errors)) {
          errors.forEach(function (err) {
            var group = form.querySelector('[data-field="' + err.field + '"]');
            if (group) {
              var errorEl = group.querySelector('.form-error');
              if (errorEl) errorEl.textContent = err.message;
              var input = getFieldInput(group);
              if (input) input.classList.add('error');
            }
          });
        }
        showToast('error', 'Validation failed');
        updateFormDirtyState(form);
        return;
      }

      Object.keys(changes).forEach(function (field) {
        var jsonPath = fieldToJsonPath(field);
        var parts = jsonPath.split('.');
        var obj = settingsInitialConfig;
        for (var i = 0; i < parts.length - 1; i++) {
          if (!obj[parts[i]]) obj[parts[i]] = {};
          obj = obj[parts[i]];
        }
        obj[parts[parts.length - 1]] = changes[field];
      });

      updateFormDirtyState(form);

      // Re-fetch to get updated restart.pending state
      fetch('/api/config')
        .then(function (r) { return r.json(); })
        .then(function (config) { checkRestartBanner(config); })
        .catch(function () {});

      showToast('success', 'Configuration saved');
    })
    .catch(function () {
      if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save'; }
      showToast('error', 'Network error');
      updateFormDirtyState(form);
    });
}

function handleFormCancel(form) {
  if (!settingsInitialConfig) return;

  var groups = form.querySelectorAll('[data-field]');
  groups.forEach(function (group) {
    if (group.classList.contains('form-group-toggle')) return;
    var field = group.dataset.field;
    var input = getFieldInput(group);
    if (!input) return;
    var jsonPath = fieldToJsonPath(field);
    var value = getNestedValue(settingsInitialConfig, jsonPath);
    setFieldValue(input, value);
  });

  clearFormErrors(form);
  updateFormDirtyState(form);
}

function attachSettingsListeners() {
  var content = document.querySelector('.page-content');
  if (!content) return;
  if (content.dataset.settingsInit) return;
  content.dataset.settingsInit = '1';

  content.addEventListener('change', function (event) {
    var group = event.target.closest('[data-field]');
    if (!group) return;

    if (group.classList.contains('form-group-toggle')) {
      handleToggleChange(group.dataset.field, event.target.checked);
      return;
    }

    var form = event.target.closest('.settings-form');
    if (form) updateFormDirtyState(form);
  });

  content.addEventListener('input', function (event) {
    var form = event.target.closest('.settings-form');
    if (form) updateFormDirtyState(form);
  });

  content.addEventListener('submit', function (event) {
    var form = event.target.closest('.settings-form');
    if (!form) return;
    event.preventDefault();
    handleFormSave(form);
  });

  content.addEventListener('click', function (event) {
    var cancelBtn = event.target.closest('.form-cancel');
    if (!cancelBtn) return;
    var form = cancelBtn.closest('.settings-form');
    if (form) handleFormCancel(form);
  });
}

function initSettingsForm() {
  var form = document.querySelector('.settings-form');
  if (!form || form.dataset.settingsInit) return;
  form.dataset.settingsInit = '1';

  // Activate initial settings tab (from URL hash or default to 'agent')
  var initialTab = (location.hash || '#agent').replace('#', '');
  if (!document.querySelector('.settings-tab[href="#' + initialTab + '"]')) initialTab = 'agent';
  activateSettingsTab(initialTab);

  fetch('/api/config')
    .then(function (res) {
      if (!res.ok) throw new Error('Failed to load config');
      return res.json();
    })
    .then(function (config) {
      settingsInitialConfig = config;
      var meta = config._meta || {};
      populateSettingsForm(config, meta);
      checkRestartBanner(config);
      attachSettingsListeners();
    })
    .catch(function (err) {
      showToast('error', err.message || 'Failed to load settings');
    });
}

// === Channel Detail Page ===

function initChannelDetail() {
  var page = document.querySelector('.channel-detail-page');
  if (!page || page.dataset.channelInit) return;
  page.dataset.channelInit = '1';

  var channelType = page.dataset.channelType;
  if (!channelType) return;

  function patchChannelConfig(path, value, onSuccess, onError) {
    var body = {};
    body[path] = value;

    fetch('/api/config', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
      .then(function (res) {
        if (!res.ok) return res.json().then(function (d) { throw d; });
        return res.json();
      })
      .then(function () {
        if (onSuccess) onSuccess();
      })
      .catch(function (err) {
        if (onError) onError(err);
      });
  }

  function syncTaskTriggerFields(enabled) {
    var fields = page.querySelector('[data-task-trigger-fields]');
    if (!fields) return;
    fields.hidden = !enabled;
    fields.setAttribute('aria-hidden', enabled ? 'false' : 'true');
  }

  // Mode selector change handler
  page.querySelectorAll('.channel-mode-select').forEach(function (select) {
    var previousValue = select.value;
    select.addEventListener('change', function () {
      var fieldKey = select.dataset.fieldKey;
      patchChannelConfig(
        'channels.' + channelType + '.' + fieldKey,
        select.value,
        function () {
          previousValue = select.value;
          syncModeCards(page, fieldKey, select.value);
          showChannelRestartBanner();
          showToast('success', 'Mode updated (restart required)');

          // Toggle mention section visibility when group_access changes
          if (fieldKey === 'group_access') {
            var mentionSection = page.querySelector('.channel-mention-section');
            if (mentionSection) {
              mentionSection.classList.toggle('channel-mention-disabled', select.value === 'disabled');
            }
          }
        },
        function (err) {
          select.value = previousValue;
          syncModeCards(page, fieldKey, previousValue);
          var msg = (err && err.error && err.error.message) || 'Failed to update mode';
          showToast('error', msg);
        },
      );
    });
  });

  page.addEventListener('click', function (e) {
    var card = e.target.closest('.channel-mode-card');
    if (!card) return;

    var fieldKey = card.dataset.modeSelect;
    var value = card.dataset.modeValue;
    var select = page.querySelector('.channel-mode-select[data-field-key="' + fieldKey + '"]');
    if (!select || select.value === value) return;

    select.value = value;
    syncModeCards(page, fieldKey, value);
    select.dispatchEvent(new Event('change', { bubbles: true }));
  });

  // DM Allowlist add handler
  var dmAddForm = page.querySelector('[data-allowlist-type="dm"]');
  if (dmAddForm) {
    dmAddForm.addEventListener('submit', function (e) {
      e.preventDefault();
      var input = dmAddForm.querySelector('.allowlist-add-input');
      var errorEl = dmAddForm.closest('.allowlist-section').querySelector('.allowlist-add-error');
      var entry = input.value.trim();
      if (!entry) return;

      if (errorEl) errorEl.textContent = '';

      fetch('/api/config/channels/' + channelType + '/dm-allowlist', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entry: entry }),
      })
        .then(function (res) {
          return res.json().then(function (data) { return { ok: res.ok, status: res.status, data: data }; });
        })
        .then(function (result) {
          if (!result.ok) {
            var msg = (result.data.error && result.data.error.message) || 'Failed to add entry';
            if (result.status === 409) msg = 'Entry already in allowlist';
            if (errorEl) errorEl.textContent = msg;
            return;
          }
          input.value = '';
          renderAllowlistEntries(page, 'dm', result.data.allowlist, channelType);
          showToast('success', 'Entry added');
        })
        .catch(function () {
          if (errorEl) errorEl.textContent = 'Network error';
        });
    });
  }

  // Group Allowlist add handler (restart-required, uses dedicated CRUD endpoints)
  var groupAddForm = page.querySelector('[data-allowlist-type="group"]');
  if (groupAddForm) {
    groupAddForm.addEventListener('submit', function (e) {
      e.preventDefault();
      var input = groupAddForm.querySelector('.allowlist-add-input');
      var errorEl = groupAddForm.closest('.allowlist-section').querySelector('.allowlist-add-error');
      var entry = input.value.trim();
      if (!entry) return;

      if (errorEl) errorEl.textContent = '';

      fetch('/api/config/channels/' + channelType + '/group-allowlist', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entry: entry }),
      })
        .then(function (res) {
          return res.json().then(function (data) { return { ok: res.ok, status: res.status, data: data }; });
        })
        .then(function (result) {
          if (!result.ok) {
            var msg = (result.data.error && result.data.error.message) || 'Failed to add entry';
            if (result.status === 409) msg = 'Entry already in group allowlist';
            if (errorEl) errorEl.textContent = msg;
            return;
          }
          input.value = '';
          renderAllowlistEntries(page, 'group', result.data.allowlist, channelType);
          showChannelRestartBanner();
          showToast('success', 'Group entry added (restart required)');
        })
        .catch(function () {
          if (errorEl) errorEl.textContent = 'Network error';
        });
    });
  }

  // Allowlist remove handler (delegated)
  page.addEventListener('click', function (e) {
    var btn = e.target.closest('.allowlist-remove');
    if (!btn) return;

    var entry = btn.dataset.entry;
    var section = btn.closest('.allowlist-section');
    var listType = section ? section.dataset.allowlist : null;

    if (listType === 'dm') {
      fetch('/api/config/channels/' + channelType + '/dm-allowlist', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entry: entry }),
      })
        .then(function (res) {
          if (!res.ok) return res.json().then(function (d) { throw d; });
          return res.json();
        })
        .then(function (data) {
          renderAllowlistEntries(page, 'dm', data.allowlist, channelType);
          showToast('success', 'Entry removed');
        })
        .catch(function (err) {
          var msg = (err && err.error && err.error.message) || 'Failed to remove entry';
          showToast('error', msg);
        });
    } else if (listType === 'group') {
      fetch('/api/config/channels/' + channelType + '/group-allowlist', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entry: entry }),
      })
        .then(function (res) {
          if (!res.ok) return res.json().then(function (d) { throw d; });
          return res.json();
        })
        .then(function (data) {
          renderAllowlistEntries(page, 'group', data.allowlist, channelType);
          showChannelRestartBanner();
          showToast('success', 'Group entry removed (restart required)');
        })
        .catch(function (err) {
          var msg = (err && err.error && err.error.message) || 'Failed to remove entry';
          showToast('error', msg);
        });
    }
  });

  // Pairing polling (only active when mode is pairing)
  initPairingPolling();

  // Mention toggle handler
  var mentionCheckbox = page.querySelector('#require-mention');
  if (mentionCheckbox) {
    mentionCheckbox.addEventListener('change', function () {
      patchChannelConfig(
        'channels.' + channelType + '.require_mention',
        mentionCheckbox.checked,
        function () {
          showChannelRestartBanner();
          showToast('success', 'Mention setting updated (restart required)');
        },
        function (err) {
          mentionCheckbox.checked = !mentionCheckbox.checked;
          var msg = (err && err.error && err.error.message) || 'Failed to update';
          showToast('error', msg);
        },
      );
    });
  }

  var taskTriggerEnabled = page.querySelector('#task-trigger-enabled');
  var taskTriggerPrefix = page.querySelector('#task-trigger-prefix');
  var taskTriggerDefaultType = page.querySelector('#task-trigger-default-type');
  var taskTriggerAutoStart = page.querySelector('#task-trigger-auto-start');

  syncTaskTriggerFields(Boolean(taskTriggerEnabled && taskTriggerEnabled.checked));

  if (taskTriggerEnabled) {
    taskTriggerEnabled.addEventListener('change', function () {
      patchChannelConfig(
        'channels.' + channelType + '.task_trigger.enabled',
        taskTriggerEnabled.checked,
        function () {
          syncTaskTriggerFields(taskTriggerEnabled.checked);
          showChannelRestartBanner();
          showToast('success', 'Task trigger updated (restart required)');
        },
        function (err) {
          taskTriggerEnabled.checked = !taskTriggerEnabled.checked;
          syncTaskTriggerFields(taskTriggerEnabled.checked);
          var msg = (err && err.error && err.error.message) || 'Failed to update task trigger';
          showToast('error', msg);
        },
      );
    });
  }

  if (taskTriggerPrefix) {
    var previousPrefix = taskTriggerPrefix.value;
    taskTriggerPrefix.addEventListener('change', function () {
      patchChannelConfig(
        'channels.' + channelType + '.task_trigger.prefix',
        taskTriggerPrefix.value,
        function () {
          previousPrefix = taskTriggerPrefix.value;
          showChannelRestartBanner();
          showToast('success', 'Task trigger prefix updated (restart required)');
        },
        function (err) {
          taskTriggerPrefix.value = previousPrefix;
          var msg = (err && err.error && err.error.message) || 'Failed to update task trigger prefix';
          showToast('error', msg);
        },
      );
    });
  }

  if (taskTriggerDefaultType) {
    var previousDefaultType = taskTriggerDefaultType.value;
    taskTriggerDefaultType.addEventListener('change', function () {
      patchChannelConfig(
        'channels.' + channelType + '.task_trigger.default_type',
        taskTriggerDefaultType.value,
        function () {
          previousDefaultType = taskTriggerDefaultType.value;
          showChannelRestartBanner();
          showToast('success', 'Task trigger default type updated (restart required)');
        },
        function (err) {
          taskTriggerDefaultType.value = previousDefaultType;
          var msg = (err && err.error && err.error.message) || 'Failed to update task trigger type';
          showToast('error', msg);
        },
      );
    });
  }

  if (taskTriggerAutoStart) {
    taskTriggerAutoStart.addEventListener('change', function () {
      patchChannelConfig(
        'channels.' + channelType + '.task_trigger.auto_start',
        taskTriggerAutoStart.checked,
        function () {
          showChannelRestartBanner();
          showToast('success', 'Task trigger start mode updated (restart required)');
        },
        function (err) {
          taskTriggerAutoStart.checked = !taskTriggerAutoStart.checked;
          var msg = (err && err.error && err.error.message) || 'Failed to update task trigger start mode';
          showToast('error', msg);
        },
      );
    });
  }
}

function renderAllowlistEntries(page, listType, entries, channelType) {
  var section = page.querySelector('[data-allowlist="' + listType + '"]');
  if (!section) return;

  var table = section.querySelector('.allowlist-table');
  table.innerHTML = '';

  if (entries.length === 0) {
    var empty = document.createElement('div');
    empty.className = 'allowlist-empty';
    empty.textContent = 'No entries';
    table.appendChild(empty);
  } else {
    entries.forEach(function (entry) {
      var row = document.createElement('div');
      row.className = 'allowlist-row';
      var stateClass = listType === 'dm' ? 'live' : 'restart';
      var stateLabel = listType === 'dm' ? 'Live' : 'Restart';
      row.innerHTML =
        '<div class="entry-stack">' +
        '<span class="entry-main">' + escapeHtml(entry) + '</span>' +
        '</div>' +
        '<span class="entry-state-badge ' + stateClass + '">' + stateLabel + '</span>' +
        '<button class="btn btn-sm btn-danger allowlist-remove" type="button" data-entry="' + escapeHtml(entry) + '">Remove</button>';
      table.appendChild(row);
    });
  }

  var countEl = section.querySelector('.allowlist-count-num');
  if (countEl) countEl.textContent = entries.length;
}

function showChannelRestartBanner() {
  var banner = document.getElementById('channel-restart-banner');
  if (banner) banner.style.display = '';
}

function escapeHtml(str) {
  var div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// === Pairing Approval Flow ===

var pairingPollInterval = null;

function initPairingPolling() {
  var page = document.querySelector('.channel-detail-page');
  if (!page) return;
  var channelType = page.dataset.channelType;
  if (!channelType) return;

  // Only poll if the pairing section exists (mode is pairing)
  var container = document.getElementById('pairing-requests-container');
  if (!container) return;

  // Stop any previous polling
  if (pairingPollInterval) clearInterval(pairingPollInterval);

  // Initial fetch
  fetchPairings(channelType, container);

  // Poll every 5 seconds
  pairingPollInterval = setInterval(function () {
    // Stop if container removed from DOM (page navigated away)
    if (!document.getElementById('pairing-requests-container')) {
      clearInterval(pairingPollInterval);
      pairingPollInterval = null;
      return;
    }
    fetchPairings(channelType, container);
  }, 5000);

  // Approve/reject handlers (delegated)
  container.addEventListener('click', function (e) {
    var approveBtn = e.target.closest('.pairing-approve');
    if (approveBtn) {
      handlePairingAction(channelType, approveBtn.dataset.code, 'confirm', container);
      return;
    }
    var rejectBtn = e.target.closest('.pairing-reject');
    if (rejectBtn) {
      handlePairingAction(channelType, rejectBtn.dataset.code, 'reject', container);
    }
  });
}

function fetchPairings(channelType, container) {
  fetch('/api/channels/' + channelType + '/dm-pairing')
    .then(function (res) {
      if (!res.ok) throw new Error('Failed to fetch pairings');
      return res.json();
    })
    .then(function (data) {
      renderPairings(container, data.pending || []);
    })
    .catch(function () {
      // Silent fail — next poll will retry
    });
}

function renderPairings(container, pairings) {
  if (pairings.length === 0) {
    container.innerHTML = '<div class="pairing-empty">No pending pairing requests</div>';
    return;
  }

  var html = '<div class="pairing-list">';
  pairings.forEach(function (p) {
    var remaining = p.remainingSeconds;
    var label = remaining > 60 ? 'waiting ' + Math.floor(remaining / 60) + 'm' : 'waiting <1m';

    html += '<div class="pairing-row">';
    html += '<div class="entry-stack">';
    html += '<div class="entry-main">' + escapeHtml(p.senderId) + '</div>';
    html += '<div class="entry-secondary">';
    if (p.displayName) html += escapeHtml(p.displayName) + ' • ';
    html += label + '</div>';
    html += '</div>';
    html += '<div class="pairing-actions">';
    html += '<button class="btn btn-sm btn-primary pairing-approve" type="button" data-code="' + escapeHtml(p.code) + '">Approve</button>';
    html += '<button class="btn btn-sm btn-danger pairing-reject" type="button" data-code="' + escapeHtml(p.code) + '">Reject</button>';
    html += '</div>';
    html += '</div>';
  });
  html += '</div>';
  container.innerHTML = html;
}

function handlePairingAction(channelType, code, action, container) {
  var endpoint = '/api/channels/' + channelType + '/dm-pairing/' + action;

  fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: code }),
  })
    .then(function (res) {
      if (!res.ok) {
        if (res.status === 404) {
          showToast('info', 'Pairing expired or already processed');
          fetchPairings(channelType, container);
          return;
        }
        return res.json().then(function (d) { throw d; });
      }
      return res.json();
    })
    .then(function (data) {
      if (!data) return;
      if (action === 'confirm') {
        showToast('success', 'Approved — added to allowlist');
        // Refresh the DM allowlist display
        var page = document.querySelector('.channel-detail-page');
        if (page) {
          fetch('/api/config/channels/' + channelType + '/dm-allowlist')
            .then(function (r) { return r.json(); })
            .then(function (d) { renderAllowlistEntries(page, 'dm', d.allowlist, channelType); })
            .catch(function () {});
        }
      } else {
        showToast('success', 'Rejected');
      }
      fetchPairings(channelType, container);
    })
    .catch(function (err) {
      var msg = (err && err.error && err.error.message) || 'Failed to process pairing';
      showToast('error', msg);
    });
}

function syncModeCards(page, fieldKey, activeValue) {
  page.querySelectorAll('.channel-mode-card[data-mode-select="' + fieldKey + '"]').forEach(function (card) {
    var active = card.dataset.modeValue === activeValue;
    card.classList.toggle('active', active);
    card.setAttribute('aria-pressed', active ? 'true' : 'false');
  });
}
