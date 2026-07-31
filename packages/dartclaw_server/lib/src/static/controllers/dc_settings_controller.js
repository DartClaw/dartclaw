import { confirmDialog, escapeHtml, reconcileRestartBanner, showToast } from './shared.js';

// `.tab` is shared vocabulary now, so every lookup is scoped to the page strip;
// a document-wide query would also collect the guard editor's tabs.
function settingsTabStrip() {
  return document.querySelector('[data-settings-tabs]');
}

function settingsTabs() {
  const strip = settingsTabStrip();
  return strip ? Array.prototype.slice.call(strip.querySelectorAll('.tab')) : [];
}

/// The tab a keyboard event moves to, or null when the key is not a tab-strip
/// key. Shared by the page strip and the guard-editor strip.
///
/// Both strips are horizontal, so the vertical arrows are deliberately left
/// alone: intercepting them would eat page scrolling from a focused tab.
/// Space is here because a `role="tab"` announces Space as activation, which an
/// anchor does not implement.
function arrowTarget(key, items, index) {
  switch (key) {
    case 'ArrowRight':
      return items[(index + 1) % items.length];
    case 'ArrowLeft':
      return items[(index - 1 + items.length) % items.length];
    case 'Home':
      return items[0];
    case 'End':
      return items[items.length - 1];
    case ' ':
    case 'Enter':
      return items[index];
    default:
      return null;
  }
}

function handleSettingsTabClick(event) {
  const strip = settingsTabStrip();
  const tab = event.target.closest('.tab');
  if (!tab || !strip || !strip.contains(tab)) return;
  event.preventDefault();

  const targetId = tab.getAttribute('href')?.replace('#', '');
  if (!targetId) return;

  requestSettingsTab(targetId);
}

function handleSettingsTabKeydown(event) {
  const strip = settingsTabStrip();
  const tab = event.target.closest('.tab');
  if (!tab || !strip || !strip.contains(tab)) return;

  const tabs = settingsTabs();
  const index = tabs.indexOf(tab);
  if (index === -1) return;
  const next = arrowTarget(event.key, tabs, index);
  if (!next) return;

  // Focus follows activation rather than leading it: a discard the operator
  // cancels must leave the strip exactly as it was, and focusing first would
  // strand it on a tab that is neither selected nor in the tab order.
  event.preventDefault();
  next.click();
}

/// The operator-initiated tab switch. Unlike the init-time activation it must
/// not hide a card holding unsaved edits without asking first; confirmDialog is
/// asynchronous, so the strip and the panels only move once it resolves.
function requestSettingsTab(tabId) {
  const leaving = dirtyFormsLeaving(document.querySelector('.settings-grid'), tabId, settingsInitialConfig);
  if (leaving.length === 0) {
    commitSettingsTab(tabId);
    return;
  }

  confirmDialog({
    title: 'Discard unsaved changes?',
    body: 'This tab has changes that have not been saved. Switching tabs discards them.',
    confirmLabel: 'Discard',
    danger: true,
  }).then(function (confirmed) {
    if (!confirmed) return;
    // Re-baseline before switching, so the same warning cannot fire again for
    // an edit the operator already chose to drop.
    leaving.forEach(handleFormCancel);
    commitSettingsTab(tabId);
  });
}

function commitSettingsTab(tabId) {
  activateSettingsTab(tabId);
  history.replaceState(null, '', '#' + tabId);
}

/// Dirty state is per-form (8 forms) while the panels are per-card (15 cards),
/// so the check runs over the forms inside every card [grid] is about to hide.
/// The incoming tab's cards and already-hidden ones are skipped, and a tab whose
/// cards hold no form yields nothing, so it switches unguarded.
///
/// A null [initialConfig] yields nothing: no comparison ever ran, so a
/// `data-dirty` flag can only be stale markup — restoring from it would be a
/// no-op and the dialog would re-fire on every departure.
export function dirtyFormsLeaving(grid, tabId, initialConfig) {
  if (!grid || !initialConfig) return [];

  const dirty = [];
  grid.querySelectorAll('[data-tab]').forEach((card) => {
    if (card.dataset.tab === tabId || card.hidden) return;
    card.querySelectorAll('.settings-form').forEach((form) => {
      if (form.dataset.dirty === 'true') dirty.push(form);
    });
  });
  return dirty;
}

function activateSettingsTab(tabId) {
  const strip = settingsTabStrip();
  // Only chase focus if the strip already had it, or the initial activation
  // would steal focus from the page on load.
  const keyboardDriven = strip ? strip.contains(document.activeElement) : false;

  settingsTabs().forEach((t) => {
    const active = t.getAttribute('href') === '#' + tabId;
    t.classList.toggle('active', active);
    t.setAttribute('aria-selected', active ? 'true' : 'false');
    // Roving tabindex: the strip is one tab stop.
    t.setAttribute('tabindex', active ? '0' : '-1');
    if (active) {
      t.scrollIntoView({block: 'nearest', inline: 'center'});
      if (keyboardDriven) t.focus();
    }
  });

  const grid = document.querySelector('.settings-grid');
  if (!grid) return;

  grid.querySelectorAll('[data-tab]').forEach((card) => {
    card.hidden = card.dataset.tab !== tabId;
  });

  const main = document.querySelector('.content-area');
  if (main) main.scrollTop = 0;
}

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

// Textarea is part of the set: Compact Instructions is a `.settings-form`
// field like any other, and feeds the dirty diff and the save payload.
function getFieldInput(group) {
  return group.querySelector('input, select, textarea');
}

function fieldSkeleton(group) {
  return group.querySelector('[data-field-skeleton]');
}

/// Swaps every skeleton-bearing field between its loading block and its
/// control. Toggle fields carry no skeleton and are left alone.
function setFieldsLoading(loading) {
  document.querySelectorAll('.settings-form [data-field]').forEach(function (group) {
    var skeleton = fieldSkeleton(group);
    if (!skeleton) return;
    skeleton.hidden = !loading;
    var input = getFieldInput(group);
    if (input) input.hidden = loading;
  });
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

function mutabilitySummaryText(mutabilities) {
  if (mutabilities.length === 1) {
    if (mutabilities[0] === 'live') return 'Changes apply live.';
    if (mutabilities[0] === 'reloadable') return 'Changes reload without a server restart.';
    return 'Changes apply after a server restart.';
  }

  var phrases = mutabilities.map(function (mutability) {
    if (mutability === 'live') return 'live';
    if (mutability === 'reloadable') return 'on reload';
    return 'after a server restart';
  });
  var joined = phrases.length === 2
    ? phrases.join(' or ')
    : phrases.slice(0, -1).join(', ') + ', or ' + phrases[phrases.length - 1];
  return 'Changes apply ' + joined + ', depending on the field.';
}

function updateMutabilitySummaries(meta) {
  var fields = meta && meta.fields ? meta.fields : {};
  document.querySelectorAll('.settings-form').forEach(function (form) {
    var card = form.closest('[data-tab]');
    var note = card && card.querySelector('[data-mutability-summary]');
    if (!note) return;

    var present = new Set();
    form.querySelectorAll('[data-field]').forEach(function (group) {
      var mutability = fields[group.dataset.field] && fields[group.dataset.field].mutable;
      if (mutability === 'live' || mutability === 'reloadable' || mutability === 'restart') {
        present.add(mutability);
      }
    });
    var mutabilities = ['live', 'reloadable', 'restart'].filter(function (tier) { return present.has(tier); });
    if (mutabilities.length === 0) return;

    // Neutral helper copy: the undiluted --warning token and the alert glyph
    // are reserved for the actual pending-restart state, which has its own
    // banner. A note shown unconditionally on seven of ten tabs is not a state.
    note.replaceChildren(document.createTextNode(mutabilitySummaryText(mutabilities)));
    note.hidden = false;
  });
}

// Blank workflow role fields fall back to the workflow defaults, and those to
// the agent settings — every step of which the config payload carries, so the
// inherited value can be named.
var inheritedFieldSources = {
  'workflow.defaults.workflow.provider': ['agent.provider'],
  'workflow.defaults.workflow.model': ['agent.model'],
  'workflow.defaults.planner.provider': ['workflow.defaults.workflow.provider', 'agent.provider'],
  'workflow.defaults.planner.model': ['workflow.defaults.workflow.model', 'agent.model'],
  'workflow.defaults.executor.provider': ['workflow.defaults.workflow.provider', 'agent.provider'],
  'workflow.defaults.executor.model': ['workflow.defaults.workflow.model', 'agent.model'],
  'workflow.defaults.reviewer.provider': ['workflow.defaults.workflow.provider', 'agent.provider'],
  'workflow.defaults.reviewer.model': ['workflow.defaults.workflow.model', 'agent.model'],
};

// FieldMeta carries no default, so for these the client can say the field is
// unset but cannot name what applies instead without inventing it.
//
// agent.max_turns is deliberately absent: it wears the 12ch numeric cap, which
// truncates the sentence to "Unset (". Its static hint carries the same fact at
// a width that can hold it.
var serverDefaultFields = ['agent.model', 'agent.effort'];

/// What an empty field says about itself. Only ever states a value the payload
/// actually carries.
function unsetFieldPlaceholder(field, config) {
  var sources = inheritedFieldSources[field];
  if (sources) {
    for (var i = 0; i < sources.length; i++) {
      var inherited = getNestedValue(config, fieldToJsonPath(sources[i]));
      if (inherited != null && inherited !== '') return 'Inherits ' + inherited;
    }
    return 'Unset (inherits the agent default)';
  }
  if (serverDefaultFields.indexOf(field) !== -1) return 'Unset (server default applies)';
  return '';
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

    // An enumerable control whose allowed-value list is empty cannot be set;
    // enabling it would offer a picker whose only row is blank.
    var settable = input.tagName !== 'SELECT' ||
      Boolean(metaField && metaField.allowedValues && metaField.allowedValues.length);
    input.disabled = !settable;
    input.placeholder = unsetFieldPlaceholder(field, config);

    var skeleton = fieldSkeleton(group);
    if (skeleton) {
      skeleton.hidden = true;
      input.hidden = false;
    }
  });
  updateMutabilitySummaries(meta);
}

/// Routes the saved config's restart state onto the shell's shared banner state.
///
/// Visibility and dismissal live in `shared.js` so this path and the shell
/// controller cannot disagree; an empty pending list is the cleared state.
function checkRestartBanner(config) {
  var meta = config._meta || {};
  var pending = meta.restartPending && Array.isArray(meta.pendingFields) ? meta.pendingFields : [];
  reconcileRestartBanner(pending);
}

/// A control reports an empty field as `''` where the config carries `null`, so
/// both are folded to null before comparison — otherwise every unset field
/// reads as an edit. This is also the shape sent to the API: clearing a field
/// means unset, and `''` would persist an empty string on a nullable field. A
/// legitimate `0` or `false` is a value and survives.
function normalizedFieldValue(value) {
  return value == null || value === '' ? null : value;
}

/// Every non-toggle field in [form] whose control no longer matches
/// [initialConfig], keyed by config path and carrying the value to send.
///
/// One traversal serves both the dirty flag and the save payload, so the two
/// cannot disagree about what changed. Toggles are excluded because they
/// auto-save through handleToggleChange; including one would mark a card dirty
/// for a change already persisted.
export function formChanges(form, initialConfig) {
  var changes = {};
  if (!initialConfig) return changes;

  form.querySelectorAll('[data-field]').forEach(function (group) {
    if (group.querySelector('.form-toggle')) return;

    var input = getFieldInput(group);
    if (!input) return;

    var field = group.dataset.field;
    var current = normalizedFieldValue(getFieldValue(input));
    var initial = normalizedFieldValue(getNestedValue(initialConfig, fieldToJsonPath(field)));
    if (current !== initial) changes[field] = current;
  });

  return changes;
}

/// Puts the dirty result where the operator and the tab-switch guard can see
/// it. Save stays inert while a save is in flight, or typing during the request
/// would re-arm it and admit a duplicate PATCH.
export function applyFormDirtyState(form, dirty) {
  form.dataset.dirty = dirty ? 'true' : 'false';
  var saveButton = form.querySelector('.form-actions .btn-primary');
  if (saveButton) saveButton.disabled = !dirty || form.dataset.saving === 'true';
}

function updateFormDirtyState(form) {
  if (!settingsInitialConfig) return;
  applyFormDirtyState(form, Object.keys(formChanges(form, settingsInitialConfig)).length > 0);
}

function clearFormErrors(form) {
  form.querySelectorAll('.form-error').forEach(function (el) { el.textContent = ''; });
  form.querySelectorAll('[aria-invalid="true"]').forEach(function (el) { el.removeAttribute('aria-invalid'); });
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

  var changes = formChanges(form, settingsInitialConfig);

  if (Object.keys(changes).length === 0) {
    showToast('info', 'No changes');
    return;
  }

  clearFormErrors(form);

  form.dataset.saving = 'true';
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
      delete form.dataset.saving;
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
              if (input) input.setAttribute('aria-invalid', 'true');
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

      var applied = (result.data && result.data.applied) || [];
      var pendingRestart = (result.data && result.data.pendingRestart) || [];
      if (pendingRestart.length === 0) {
        showToast('success', 'Applied');
      } else if (applied.length === 0) {
        showToast('info', 'Configuration saved — restart required');
      } else {
        showToast('info', 'Applied (' + applied.length + ' field' + (applied.length !== 1 ? 's' : '') + ') — restart required for ' + pendingRestart.length + ' field' + (pendingRestart.length !== 1 ? 's' : ''));
      }
    })
    .catch(function () {
      delete form.dataset.saving;
      if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save'; }
      showToast('error', 'Network error');
      updateFormDirtyState(form);
    });
}

function handleFormCancel(form) {
  if (!settingsInitialConfig) return;

  var groups = form.querySelectorAll('[data-field]');
  groups.forEach(function (group) {
    if (group.querySelector('.form-toggle')) return;
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
  var content = document.querySelector('.content-area');
  if (!content) return;
  if (content.dataset.settingsInit) return;
  content.dataset.settingsInit = '1';

  content.addEventListener('change', function (event) {
    var group = event.target.closest('[data-field]');
    if (!group) return;

    if (group.querySelector('.form-toggle')) {
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
    var cancelBtn = event.target.closest('[data-form-cancel]');
    if (!cancelBtn) return;
    var form = cancelBtn.closest('.settings-form');
    if (form) handleFormCancel(form);
  });
}

var guardEditorState = null;
var activeGuardEditorGuard = 'command';

var guardFieldLabels = {
  command: {
    extra_blocked_patterns: 'Blocked pattern',
    extra_blocked_pipe_targets: 'Blocked pipe target',
  },
  file: {
    extra_rules: 'File rule',
  },
  network: {
    extra_allowed_domains: 'Allowed domain',
    extra_exfil_patterns: 'Exfiltration pattern',
  },
  'input-sanitizer': {
    extra_patterns: 'Input pattern',
  },
};

function currentGuardEditorGroup() {
  if (!guardEditorState) return null;
  return guardEditorState.guards.find(function (group) { return group.guard === activeGuardEditorGuard; });
}

function guardEntryDisplay(value) {
  if (value && typeof value === 'object') {
    if ('pattern' in value && 'level' in value) return value.pattern + ' -> ' + value.level;
    return JSON.stringify(value);
  }
  return String(value);
}

// The guard editor re-renders its rows with fresh data-index values whenever the
// state refreshes, so an index captured before a dialog can address a different
// rule after it. Re-resolve against the entry's rendered display; -1 means the
// rule the user acted on is no longer there.
function resolveGuardEntryIndex(guard, field, index, display) {
  if (activeGuardEditorGuard !== guard) return -1;
  var group = currentGuardEditorGroup();
  var entries = (group && group.fields && group.fields[field]) || [];
  if (index >= 0 && index < entries.length && guardEntryDisplay(entries[index]) === display) return index;
  return entries.findIndex(function (entry) {
    return guardEntryDisplay(entry) === display;
  });
}

// Structured input: composes the canonical frame and the shared form controls
// rather than defining a frame of its own. Deliberately not folded into
// confirmDialog(), which has no field slot and must not grow one.
// Resolves the submitted values, or null when cancelled.
function openGuardEntryDialog(options) {
  var dialog = document.createElement('dialog');
  dialog.className = 'dialog dialog--md card card-glass';
  dialog.setAttribute('aria-label', options.title);

  var form = document.createElement('form');
  form.method = 'dialog';

  var header = document.createElement('div');
  header.className = 'dialog-header';
  var heading = document.createElement('h3');
  heading.className = 't-heading';
  heading.textContent = options.title;
  header.appendChild(heading);

  var body = document.createElement('div');
  body.className = 'dialog-body';

  var valueField = document.createElement('div');
  valueField.className = 'form-field';
  var valueLabel = document.createElement('label');
  valueLabel.className = 'form-label t-caption tracking-caps';
  valueLabel.htmlFor = 'guard-entry-value';
  valueLabel.textContent = options.valueLabel;
  var valueInput = document.createElement('input');
  valueInput.type = 'text';
  valueInput.id = 'guard-entry-value';
  valueInput.className = 'form-input';
  valueInput.value = options.value || '';
  valueField.append(valueLabel, valueInput);
  body.appendChild(valueField);

  // Mirrors the Add form's level select rather than asking the user to free-type
  // one of the three legal values.
  var levelSelect = null;
  if (options.level != null) {
    var levelField = document.createElement('div');
    levelField.className = 'form-field';
    var levelLabel = document.createElement('label');
    levelLabel.className = 'form-label t-caption tracking-caps';
    levelLabel.htmlFor = 'guard-entry-level';
    levelLabel.textContent = 'File access level';
    levelSelect = document.createElement('select');
    levelSelect.id = 'guard-entry-level';
    levelSelect.className = 'form-select';
    [['no_access', 'No access'], ['read_only', 'Read only'], ['no_delete', 'No delete']].forEach(function (pair) {
      var option = document.createElement('option');
      option.value = pair[0];
      option.textContent = pair[1];
      levelSelect.appendChild(option);
    });
    levelSelect.value = options.level;
    levelField.append(levelLabel, levelSelect);
    body.appendChild(levelField);
  }

  var cancelButton = document.createElement('button');
  cancelButton.type = 'button';
  cancelButton.className = 'btn btn-ghost btn-sm';
  cancelButton.textContent = 'Cancel';

  var saveButton = document.createElement('button');
  saveButton.type = 'submit';
  saveButton.className = 'btn btn-primary btn-sm';
  saveButton.textContent = 'Save';

  var actions = document.createElement('div');
  actions.className = 'dialog-actions';
  actions.append(cancelButton, saveButton);
  var footer = document.createElement('div');
  footer.className = 'dialog-footer';
  footer.appendChild(actions);

  form.append(header, body, footer);
  dialog.appendChild(form);
  document.body.appendChild(dialog);

  return new Promise(function (resolve) {
    var submitted = null;
    dialog.addEventListener('close', function () {
      dialog.remove();
      resolve(submitted);
    }, { once: true });
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      var value = valueInput.value.trim();
      if (!value) {
        valueInput.focus();
        return;
      }
      submitted = { value: value, level: levelSelect ? levelSelect.value : null };
      dialog.close();
    });
    cancelButton.addEventListener('click', function () {
      dialog.close();
    });
    dialog.showModal();
    valueInput.focus();
    valueInput.select();
  });
}

async function handleGuardEntryEdit(edit) {
  var group = currentGuardEditorGroup();
  if (!group) return;
  // Capture everything the dialog needs before the first await.
  var guard = activeGuardEditorGuard;
  var field = edit.dataset.guardEditorEdit;
  var index = Number(edit.dataset.index);
  var entries = (group.fields && group.fields[field]) || [];
  var current = entries[index];
  if (current === undefined) return;
  var display = guardEntryDisplay(current);
  var isFileRule = group.guard === 'file' && field === 'extra_rules';
  var label = (guardFieldLabels[group.guard] || {})[field] || field;

  var submitted = await openGuardEntryDialog({
    title: 'Edit ' + label,
    valueLabel: isFileRule ? 'Pattern' : label,
    value: isFileRule && current && current.pattern ? current.pattern : display,
    level: isFileRule ? (current && current.level) || 'no_access' : null,
  });
  if (!submitted) return;

  var resolvedIndex = resolveGuardEntryIndex(guard, field, index, display);
  if (resolvedIndex < 0) {
    showToast('error', 'That guard extension changed while you were editing – reopen it and try again.');
    return;
  }

  var body = isFileRule ? { pattern: submitted.value, level: submitted.level } : { value: submitted.value };
  fetch('/api/config/guards/' + guard + '/' + field + '/' + resolvedIndex, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
    .then(function (res) {
      if (!res.ok) return res.json().then(function (data) { throw data; });
      return res.json();
    })
    .then(function (mutation) {
      return refreshGuardEditorState().then(function () {
        showGuardMutationToast('Guard extension updated', mutation);
      });
    })
    .catch(function (err) {
      showToast('error', (err.errors && err.errors[0] && err.errors[0].message) || 'Update failed');
    });
}

async function handleGuardEntryDelete(del) {
  var group = currentGuardEditorGroup();
  if (!group) return;
  var guard = activeGuardEditorGuard;
  var field = del.dataset.guardEditorDelete;
  var index = Number(del.dataset.index);
  var entries = (group.fields && group.fields[field]) || [];
  var current = entries[index];
  if (current === undefined) return;
  // File extra_rules entries are objects; guardEntryDisplay is what the row shows.
  var display = guardEntryDisplay(current);
  var label = (guardFieldLabels[group.guard] || {})[field] || field;

  var confirmed = await confirmDialog({
    title: 'Delete guard extension',
    body: 'Delete ' + label + ' "' + display + '" from the ' + guard + ' guard?',
    confirmLabel: 'Delete',
    danger: true,
  });
  if (!confirmed) return;

  var resolvedIndex = resolveGuardEntryIndex(guard, field, index, display);
  if (resolvedIndex < 0) {
    showToast('error', 'That guard extension changed while you were editing – reopen it and try again.');
    return;
  }

  fetch('/api/config/guards/' + guard + '/' + field + '/' + resolvedIndex, {
    method: 'DELETE',
  })
    .then(function (res) {
      if (!res.ok) return res.json().then(function (data) { throw data; });
      return res.json();
    })
    .then(function (mutation) {
      return refreshGuardEditorState().then(function () {
        showGuardMutationToast('Guard extension deleted', mutation);
      });
    })
    .catch(function (err) {
      showToast('error', (err.errors && err.errors[0] && err.errors[0].message) || 'Delete failed');
    });
}

function renderGuardEditor() {
  var root = document.querySelector('[data-guard-editor]');
  if (!root || !guardEditorState) return;

  var tabs = root.querySelector('[data-guard-editor-tabs]');
  var rows = root.querySelector('[data-guard-editor-rows]');
  var fieldSelect = root.querySelector('[data-guard-editor-field]');
  var levelSelect = root.querySelector('[data-guard-editor-level]');
  var testModeSelect = root.querySelector('[data-guard-editor-test-mode]');
  var result = root.querySelector('[data-guard-editor-result]');
  var group = currentGuardEditorGroup();

  if (tabs) {
    tabs.innerHTML = guardEditorState.guards.map(function (guard) {
      var active = guard.guard === activeGuardEditorGuard;
      var id = 'guard-editor-tab-' + escapeHtml(guard.guard);
      return '<button type="button" role="tab" class="tab t-label' + (active ? ' active' : '') +
        '" id="' + id + '" aria-selected="' + (active ? 'true' : 'false') +
        '" tabindex="' + (active ? '0' : '-1') +
        '" aria-controls="guard-editor-panel" data-guard-editor-tab="' + escapeHtml(guard.guard) + '">' +
        escapeHtml(guard.guard) + '</button>';
    }).join('');
  }

  var panel = root.querySelector('#guard-editor-panel');
  if (panel) panel.setAttribute('aria-labelledby', 'guard-editor-tab-' + activeGuardEditorGuard);

  if (!group) return;
  var labels = guardFieldLabels[group.guard] || {};
  var rowHtml = [];
  Object.keys(group.fields || {}).forEach(function (field) {
    var entries = group.fields[field] || [];
    if (!entries.length) {
      rowHtml.push('<tr><td>-</td><td>' + escapeHtml(labels[field] || field) + '</td><td class="guard-editor-message">No editable extensions</td><td></td></tr>');
      return;
    }
    entries.forEach(function (entry, index) {
      var controls = '<td><button type="button" class="btn btn-ghost btn-sm" data-guard-editor-edit="' + escapeHtml(field) + '" data-index="' + index + '">Edit</button><button type="button" class="btn btn-ghost btn-sm" data-guard-editor-delete="' + escapeHtml(field) + '" data-index="' + index + '">Delete</button></td>';
      rowHtml.push('<tr><td>' + (index + 1) + '</td><td>' + escapeHtml(labels[field] || field) + '</td><td class="guard-editor-value">' + escapeHtml(guardEntryDisplay(entry)) + '</td>' + controls + '</tr>');
    });
  });
  if (rows) {
    rows.innerHTML = rowHtml.join('');
  }

  if (fieldSelect) {
    fieldSelect.innerHTML = Object.keys(labels).map(function (field) {
      return '<option value="' + escapeHtml(field) + '">' + escapeHtml(labels[field]) + '</option>';
    }).join('');
    var isFileRule = group.guard === 'file' && fieldSelect.value === 'extra_rules';
    if (levelSelect) levelSelect.hidden = !isFileRule;
  }
  if (testModeSelect) testModeSelect.hidden = group.guard !== 'file';
  if (result && guardEditorState.displayedLayer) {
    result.textContent = 'Showing ' + guardEditorState.displayedLayer;
  }
  if (result && guardEditorState.pendingRestart && guardEditorState.pendingRestart.length) {
    result.classList.remove('guard-editor-error');
    result.textContent = 'Showing ' + (guardEditorState.displayedLayer || 'persisted-config') + '. Pending restart: ' + guardEditorState.pendingRestart.join(', ');
  }
}

function loadGuardEditor() {
  var root = document.querySelector('[data-guard-editor]');
  if (!root || root.dataset.loaded) return;

  var existing = root.querySelector('[data-guard-editor-error]');
  if (existing) existing.remove();

  fetch('/api/config/guards')
    .then(function (res) {
      if (!res.ok) throw new Error('Failed to load guard editor');
      return res.json();
    })
    .then(function (state) {
      // Success only: the flag suppresses re-entry, so setting it before the
      // request resolves would make a failed load permanent and Retry inert.
      root.dataset.loaded = '1';
      guardEditorState = state;
      renderGuardEditor();
    })
    .catch(function (err) {
      var rows = root.querySelector('[data-guard-editor-rows]');
      if (rows) rows.replaceChildren();
      var banner = inlineErrorBanner(
        'data-guard-editor-error',
        err.message || 'Failed to load guard editor',
        loadGuardEditor,
      );
      root.insertBefore(banner, root.querySelector('[data-guard-editor-tabs]'));
    });
}

function guardEditorPayload(root) {
  var group = currentGuardEditorGroup();
  var field = root.querySelector('[data-guard-editor-field]')?.value;
  var value = root.querySelector('[data-guard-editor-value]')?.value.trim();
  if (!group || !field || !value) return null;
  if (group.guard === 'file' && field === 'extra_rules') {
    return { field: field, body: { pattern: value, level: root.querySelector('[data-guard-editor-level]')?.value || 'no_access' } };
  }
  return { field: field, body: { value: value } };
}

function attachGuardEditorListeners() {
  var root = document.querySelector('[data-guard-editor]');
  if (!root || root.dataset.listeners) return;
  root.dataset.listeners = '1';

  root.addEventListener('keydown', function (event) {
    var tab = event.target.closest('[data-guard-editor-tab]');
    if (!tab) return;
    var tabs = Array.prototype.slice.call(root.querySelectorAll('[data-guard-editor-tab]'));
    var index = tabs.indexOf(tab);
    if (index === -1) return;
    var next = arrowTarget(event.key, tabs, index);
    if (!next) return;
    event.preventDefault();
    next.click();
  });

  root.addEventListener('click', function (event) {
    var tab = event.target.closest('[data-guard-editor-tab]');
    if (tab) {
      activeGuardEditorGuard = tab.dataset.guardEditorTab;
      renderGuardEditor();
      // The strip is re-rendered from scratch, so the element that was focused
      // is gone; move focus onto its replacement or arrow keys stop working
      // after the first press.
      var selected = root.querySelector('[data-guard-editor-tab][aria-selected="true"]');
      if (selected) selected.focus();
      return;
    }

    var edit = event.target.closest('[data-guard-editor-edit]');
    if (edit) {
      handleGuardEntryEdit(edit);
      return;
    }

    var del = event.target.closest('[data-guard-editor-delete]');
    if (!del) return;
    handleGuardEntryDelete(del);
  });

  root.addEventListener('change', function (event) {
    if (event.target.matches('[data-guard-editor-field]')) renderGuardEditor();
  });

  var addForm = root.querySelector('[data-guard-editor-add]');
  if (addForm) {
    addForm.addEventListener('submit', function (event) {
      event.preventDefault();
      var payload = guardEditorPayload(root);
      if (!payload) return;
      fetch('/api/config/guards/' + activeGuardEditorGuard + '/' + payload.field, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload.body),
      })
        .then(function (res) {
          if (!res.ok) return res.json().then(function (data) { throw data; });
          return res.json();
        })
        .then(function (mutation) {
          var input = root.querySelector('[data-guard-editor-value]');
          if (input) input.value = '';
          return refreshGuardEditorState().then(function () {
            showGuardMutationToast('Guard extension saved', mutation);
          });
        })
        .catch(function (err) {
          showToast('error', (err.errors && err.errors[0] && err.errors[0].message) || 'Save failed');
        });
    });
  }

  var tester = root.querySelector('[data-guard-editor-test]');
  if (tester) {
    tester.addEventListener('submit', function (event) {
      event.preventDefault();
      var input = root.querySelector('[data-guard-editor-test-input]');
      var mode = root.querySelector('[data-guard-editor-test-mode]');
      var result = root.querySelector('[data-guard-editor-result]');
      var payload = { guard: activeGuardEditorGuard, input: input ? input.value : '' };
      var draft = guardEditorPayload(root);
      if (draft && draft.body && root.querySelector('[data-guard-editor-value]')?.value.trim()) {
        payload.candidate = { field: draft.field, value: activeGuardEditorGuard === 'file' ? draft.body : draft.body.value };
      }
      if (activeGuardEditorGuard === 'file' && mode) {
        payload.input = { input: input ? input.value : '', mode: mode.value };
      }
      fetch('/api/config/guards/test', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
        .then(function (res) {
          if (!res.ok) return res.json().then(function (data) { throw data; });
          return res.json();
        })
        .then(function (data) {
          if (result) {
            result.classList.remove('guard-editor-error');
            var layer = data.evaluatedLayer ? ' [' + data.evaluatedLayer + ']' : '';
            result.textContent = data.verdict.toUpperCase() + layer + (data.reason ? ': ' + data.reason : '');
          }
        })
        .catch(function (err) {
          if (result) {
            result.classList.add('guard-editor-error');
            result.textContent = (err.errors && err.errors[0] && err.errors[0].message) || 'Test failed';
          }
        });
    });
  }
}

function refreshGuardEditorState() {
  return fetch('/api/config/guards')
    .then(function (r) { return r.json(); })
    .then(function (state) {
      guardEditorState = state;
      renderGuardEditor();
    });
}

function showGuardMutationToast(message, mutation) {
  var pending = mutation && mutation.pendingRestart ? mutation.pendingRestart.length : 0;
  var applied = mutation && mutation.applied ? mutation.applied.length : 0;
  if (pending > 0 && applied === 0) {
    showToast('info', message + ' — restart required');
  } else if (pending > 0) {
    showToast('info', message + ' — some changes pending restart');
  } else {
    showToast('success', message);
  }
}

/// An in-page failure that outlives a toast: the card keeps a banner with a
/// Retry until the load succeeds. [marker] keeps the two fetches' banners
/// independently clearable.
function inlineErrorBanner(marker, message, onRetry) {
  var banner = document.createElement('div');
  banner.className = 'banner banner-error';
  banner.setAttribute(marker, '');
  banner.setAttribute('role', 'alert');

  var icon = document.createElement('span');
  icon.className = 'icon icon-triangle-alert';
  icon.setAttribute('aria-hidden', 'true');

  var text = document.createElement('span');
  text.textContent = message;

  var retry = document.createElement('button');
  retry.type = 'button';
  retry.className = 'btn btn-ghost btn-sm';
  retry.textContent = 'Retry';
  retry.addEventListener('click', onRetry);

  banner.append(icon, text, retry);
  return banner;
}

function clearSettingsLoadError() {
  document.querySelectorAll('[data-settings-error]').forEach(function (el) { el.remove(); });
}

function showSettingsLoadError(message) {
  document.querySelectorAll('.settings-form').forEach(function (form) {
    var card = form.closest('[data-tab]');
    if (!card || card.querySelector('[data-settings-error]')) return;
    card.insertBefore(inlineErrorBanner('data-settings-error', message, loadSettingsConfig), form);
  });
}

/// The whole success pipeline, re-runnable from Retry. Repopulating alone would
/// leave a form that looks live but has no dirty tracking, no save and no guard
/// editor, because the baseline and the listeners are set here too.
function loadSettingsConfig() {
  clearSettingsLoadError();
  setFieldsLoading(true);

  return fetch('/api/config')
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
      loadGuardEditor();
      attachGuardEditorListeners();
      // Re-baseline after every populate, including a Retry-driven one, so a
      // freshly loaded form reads clean rather than as a phantom edit.
      document.querySelectorAll('.settings-form').forEach(updateFormDirtyState);
    })
    .catch(function (err) {
      // The controls come back as their own inert selves rather than staying
      // behind a skeleton that would keep claiming the load is in flight.
      setFieldsLoading(false);
      showSettingsLoadError('Settings could not be loaded.');
      showToast('error', err.message || 'Failed to load settings');
    });
}

function initSettingsForm() {
  var form = document.querySelector('.settings-form');
  if (!form || form.dataset.settingsInit) return;
  form.dataset.settingsInit = '1';

  // Activate initial settings tab (from URL hash or default to 'agent').
  // Deliberately not the operator path: no field has been edited yet, and a
  // discard confirmation here would block page load behind a dialog.
  var strip = settingsTabStrip();
  var initialTab = (location.hash || '#agent').replace('#', '');
  if (!strip || !strip.querySelector('.tab[href="#' + initialTab + '"]')) initialTab = 'agent';
  activateSettingsTab(initialTab);

  // Before the fetch resolves and after it fails there is still a Save button
  // on screen; without the submit listener it would navigate and take the
  // failure banner with it. Both handlers no-op until a baseline exists.
  attachSettingsListeners();
  loadSettingsConfig();
}

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

  // Mode selector change handler. Selection moves immediately; the write is
  // debounced and serialized — see createModeCommitScheduler.
  cancelModeCommits();
  page.querySelectorAll('.channel-mode-select').forEach(function (select) {
    var fieldKey = select.dataset.fieldKey;
    if (!fieldKey) return;

    modeCommitSchedulers[fieldKey] = createModeCommitScheduler({
      delayMs: MODE_COMMIT_DELAY_MS,
      initialValue: select.value,
      patch: function (value, onSuccess, onError) {
        patchChannelConfig('channels.' + channelType + '.' + fieldKey, value, onSuccess, onError);
      },
      onCommitted: function (value) {
        syncModeCards(page, fieldKey, value);
        showChannelRestartBanner();
        showToast('success', 'Mode updated (restart required)');

        // Toggle mention section visibility when group_access changes
        if (fieldKey === 'group_access') {
          var mentionSection = page.querySelector('.channel-mention-section');
          if (mentionSection) {
            mentionSection.classList.toggle('channel-mention-disabled', value === 'disabled');
          }
        }
      },
      onFailed: function (rollbackTo, err) {
        select.value = rollbackTo;
        syncModeCards(page, fieldKey, rollbackTo);
        var msg = (err && err.error && err.error.message) || 'Failed to update mode';
        showToast('error', msg);
      },
    });

    select.addEventListener('change', function () {
      modeCommitSchedulers[fieldKey].schedule(select.value);
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

  page.addEventListener('keydown', function (e) {
    handleModeCardKeydown(page, e);
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
  page.addEventListener('click', async function (e) {
    var btn = e.target.closest('.allowlist-remove');
    if (!btn) return;

    // Both reads must happen before the await: renderAllowlistEntries() can
    // replace the button and its section while the dialog is open.
    var entry = btn.dataset.entry;
    var section = btn.closest('.allowlist-section');
    var listType = section ? section.dataset.allowlist : null;
    if (listType !== 'dm' && listType !== 'group') return;

    // These two gate who may message the agent and there is no undo, so the
    // confirmation sits above the branch and guards both DELETEs.
    var confirmed = await confirmDialog({
      title: 'Remove allowlist entry',
      body: 'Remove "' + entry + '" from the ' +
        (listType === 'dm' ? 'Known DM Allowlist' : 'Allowed Groups') +
        '? They will no longer be able to reach the agent.',
      confirmLabel: 'Remove',
      danger: true,
    });
    if (!confirmed) return;

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

  // Pairing polling is started by the caller, which also covers the path where
  // this function early-returns on an already-initialised page.

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
    empty.className = 'text-muted';
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
  if (banner) banner.hidden = false;
}

/// How long a mode selection must sit still before it is written.
var MODE_COMMIT_DELAY_MS = 350;

var modeCommitSchedulers = {};

function cancelModeCommits() {
  Object.keys(modeCommitSchedulers).forEach(function (key) {
    modeCommitSchedulers[key].cancel();
  });
  modeCommitSchedulers = {};
}

/// Debounced, serialized writer for one channel access-mode field.
///
/// Arrow keys move selection on every keypress, so writing per change would
/// persist every mode the operator passes through — for `dm_access` that means
/// briefly saving an access policy nobody chose. Selection still moves
/// immediately; only the write waits for the selection to settle.
///
/// Requests are serialized: at most one is in flight, and each captures its own
/// rollback value at dispatch. A shared rollback would restore whatever the
/// last handler happened to see, so an overlapping failure could reinstate a
/// mode that was never the committed one.
///
/// [options] takes `delayMs`, `initialValue`, `patch(value, onSuccess, onError)`
/// and optional `onCommitted(value)` / `onFailed(rollbackTo, error)` callbacks.
/// `setTimeoutFn` / `clearTimeoutFn` are injectable so the scheduler can be
/// driven without real timers.
export function createModeCommitScheduler(options) {
  var delayMs = options.delayMs;
  var patch = options.patch;
  var scheduleTimer = options.setTimeoutFn || setTimeout;
  var cancelTimer = options.clearTimeoutFn || clearTimeout;

  var timer = null;
  var pending = null;
  var hasPending = false;
  var inFlight = false;
  var committed = options.initialValue;

  function flush() {
    if (inFlight || !hasPending) return;
    var value = pending;
    hasPending = false;
    pending = null;
    if (value === committed) return;

    var rollbackTo = committed;
    inFlight = true;
    patch(
      value,
      function () {
        inFlight = false;
        committed = value;
        if (options.onCommitted) options.onCommitted(value);
        // Drain anything queued while this request was in flight.
        flush();
      },
      function (err) {
        inFlight = false;
        // The server refused this value; anything queued behind it was typed
        // against a state that never existed, so drop it rather than replay.
        hasPending = false;
        pending = null;
        if (options.onFailed) options.onFailed(rollbackTo, err);
      },
    );
  }

  return {
    schedule: function (value) {
      pending = value;
      hasPending = true;
      if (timer !== null) cancelTimer(timer);
      timer = scheduleTimer(function () {
        timer = null;
        flush();
      }, delayMs);
    },
    cancel: function () {
      if (timer !== null) cancelTimer(timer);
      timer = null;
      hasPending = false;
      pending = null;
    },
    committedValue: function () {
      return committed;
    },
    isIdle: function () {
      return timer === null && !hasPending && !inFlight;
    },
  };
}

var pairingPollInterval = null;

function initPairingPolling() {
  var page = document.querySelector('.channel-detail-page');
  if (!page) return;
  var channelType = page.dataset.channelType;
  if (!channelType) return;

  // The pairing section always renders, so visibility — not presence — decides
  // whether to poll. A hidden section must issue no request.
  var container = document.getElementById('pairing-requests-container');
  if (!container) return;
  var section = container.closest('[data-section="pairing"]');
  if (section && section.hidden) return;

  // Stop any previous polling
  if (pairingPollInterval) clearInterval(pairingPollInterval);

  // Initial fetch
  fetchPairings(channelType, container);

  // Poll every 5 seconds
  pairingPollInterval = setInterval(function () {
    // Stop if the container left the DOM (navigated away) or was hidden.
    var live = document.getElementById('pairing-requests-container');
    var liveSection = live && live.closest('[data-section="pairing"]');
    if (!live || (liveSection && liveSection.hidden)) {
      clearInterval(pairingPollInterval);
      pairingPollInterval = null;
      return;
    }
    fetchPairings(channelType, container);
  }, 5000);

  // Approve/reject handlers (delegated). Bound once per container: the section
  // can now be shown and hidden repeatedly without a reload.
  if (!container.dataset.pairingActionsBound) {
    container.dataset.pairingActionsBound = 'true';
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
    container.innerHTML = '<div class="text-muted">No pending pairing requests</div>';
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
    card.setAttribute('aria-checked', active ? 'true' : 'false');
    // Roving tabindex: the radiogroup is one tab stop.
    card.setAttribute('tabindex', active ? '0' : '-1');

    // The ACTIVE badge is server-rendered, so it has to be created and removed
    // here too or two cards claim to be active until a full reload.
    var label = card.querySelector('.channel-mode-card-label');
    var badge = label ? label.querySelector('.channel-mode-badge') : null;
    if (active && label && !badge) {
      badge = document.createElement('span');
      badge.className = 'channel-mode-badge';
      badge.textContent = 'Active';
      label.appendChild(badge);
    } else if (!active && badge) {
      badge.remove();
    }
  });

  if (fieldKey === 'dm_access') syncPairingSection(page, activeValue);
}

/// Shows the pairing sub-card only while DM mode is `pairing`, and starts or
/// stops its 5s poll with it — the hint promises exactly this.
function syncPairingSection(page, dmMode) {
  var section = page.querySelector('[data-section="pairing"]');
  if (!section) return;
  var shouldShow = dmMode === 'pairing';
  if (section.hidden === !shouldShow) return;
  section.hidden = !shouldShow;
  if (shouldShow) {
    initPairingPolling();
  } else {
    cleanupPairingPolling();
  }
}

/// Arrow keys move focus and selection inside a mode radiogroup; Space and
/// Enter select the focused radio. Selection routes through the same click path
/// so the paired select and the existing save call are unchanged.
function handleModeCardKeydown(page, event) {
  var card = event.target.closest('.channel-mode-card');
  if (!card) return;
  var group = card.closest('[role="radiogroup"]');
  if (!group) return;

  var cards = Array.prototype.slice.call(group.querySelectorAll('.channel-mode-card'));
  var index = cards.indexOf(card);
  if (index === -1) return;

  var next = null;
  switch (event.key) {
    case 'ArrowRight':
    case 'ArrowDown':
      next = cards[(index + 1) % cards.length];
      break;
    case 'ArrowLeft':
    case 'ArrowUp':
      next = cards[(index - 1 + cards.length) % cards.length];
      break;
    case 'Home':
      next = cards[0];
      break;
    case 'End':
      next = cards[cards.length - 1];
      break;
    case ' ':
    case 'Enter':
      event.preventDefault();
      card.click();
      return;
    default:
      return;
  }

  event.preventDefault();
  next.focus();
  next.click();
}

function runSettingsInitializers() {
  initSettingsForm();
  initChannelDetail();
  initPairingPolling();
}

function cleanupPairingPolling() {
  if (pairingPollInterval) {
    clearInterval(pairingPollInterval);
    pairingPollInterval = null;
  }
}

export function runChannelDetailInitializers() {
  initChannelDetail();
  initPairingPolling();
}

export function cleanupChannelDetail() {
  cleanupPairingPolling();
  // Drop any selection that has not settled yet, so a pending write cannot
  // land after the page is gone.
  cancelModeCommits();
}

export default class DcSettingsController extends Stimulus.Controller {
  connect() {
    this.element.addEventListener('click', handleSettingsTabClick);
    this.element.addEventListener('keydown', handleSettingsTabKeydown);
    runSettingsInitializers();
  }

  disconnect() {
    this.element.removeEventListener('click', handleSettingsTabClick);
    this.element.removeEventListener('keydown', handleSettingsTabKeydown);
    cleanupPairingPolling();
  }
}
