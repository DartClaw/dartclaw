import { confirmDialog } from './shared.js';

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
  const leaving = dirtyFormsLeaving(document.querySelector('.settings-grid'), tabId);
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
    leaving.forEach(discardFormEdits);
    commitSettingsTab(tabId);
  });
}

/// Restores the server-rendered control defaults — the same baseline the dirty
/// diff compares against, so no client-side value cache exists to go stale.
function discardFormEdits(form) {
  form.reset();
  updateFormDirtyState(form);
}

function commitSettingsTab(tabId) {
  activateSettingsTab(tabId);
  history.replaceState(null, '', '#' + tabId);
}

/// Dirty state is per-form while the panels are per-card, so the check runs
/// over the forms inside every card [grid] is about to hide. The incoming tab's
/// cards and already-hidden ones are skipped, and a tab whose cards hold no
/// form yields nothing, so it switches unguarded.
export function dirtyFormsLeaving(grid, tabId) {
  if (!grid) return [];

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

// The values arrive in the page, so a control's own server-rendered default is
// the dirty baseline — there is no client-side config to cache or invalidate.
function getFieldInput(group) {
  return group.querySelector('input, select, textarea');
}

function controlChanged(input) {
  if (input.type === 'checkbox') return input.checked !== input.defaultChecked;
  if (input.tagName === 'SELECT') {
    var options = Array.prototype.slice.call(input.options);
    var initial = options.filter(function (option) { return option.defaultSelected; })[0] || options[0];
    return input.value !== (initial ? initial.value : '');
  }
  return input.value !== input.defaultValue;
}

/// The `data-field` paths in [form] whose control no longer carries the value
/// the server rendered into it.
///
/// One traversal serves both the dirty flag and the tab-switch guard, so the
/// two cannot disagree about what changed.
export function formChanges(form) {
  var changed = [];
  form.querySelectorAll('[data-field]').forEach(function (group) {
    var input = getFieldInput(group);
    if (!input || input.disabled) return;
    if (controlChanged(input)) changed.push(group.dataset.field);
  });
  return changed;
}

/// Puts the dirty result where the operator and the tab-switch guard can see
/// it. Save stays inert while a save is in flight, or typing during the request
/// would re-arm it and admit a duplicate submission.
export function applyFormDirtyState(form, dirty) {
  form.dataset.dirty = dirty ? 'true' : 'false';
  var saveButton = form.querySelector('.form-actions .btn-primary');
  if (saveButton) saveButton.disabled = !dirty || form.dataset.saving === 'true';
}

function updateFormDirtyState(form) {
  applyFormDirtyState(form, formChanges(form).length > 0);
}

function attachSettingsListeners() {
  var content = document.querySelector('.content-area');
  if (!content) return;
  if (content.dataset.settingsInit) return;
  content.dataset.settingsInit = '1';

  content.addEventListener('change', function (event) {
    var form = event.target.closest('.settings-form');
    if (form) updateFormDirtyState(form);
  });

  content.addEventListener('input', function (event) {
    var form = event.target.closest('.settings-form');
    if (form) updateFormDirtyState(form);
  });

  // A reset event fires before the browser restores the defaults, so the
  // re-baseline has to wait for the control values it is about to read.
  content.addEventListener('reset', function (event) {
    var form = event.target.closest('.settings-form');
    if (form) setTimeout(function () { updateFormDirtyState(form); }, 0);
  });

  // Editing a refused field clears its own message, so an error cannot outlive
  // the value it named.
  content.addEventListener('input', clearFieldError);
  content.addEventListener('change', clearFieldError);

  // The form posts through HTMX and a 2xx replaces it, so the only window where
  // Save could be re-armed is while the request is in flight. A refused or
  // failed request swaps nothing, so the flag has to be cleared explicitly —
  // without that the section stays permanently unsavable.
  content.addEventListener('htmx:beforeRequest', function (event) {
    var form = settingsFormFor(event.target);
    if (!form) return;
    form.dataset.saving = 'true';
    applyFormDirtyState(form, form.dataset.dirty === 'true');
  });

  ['htmx:afterRequest', 'htmx:sendError', 'htmx:responseError'].forEach(function (name) {
    content.addEventListener(name, function (event) {
      var form = settingsFormFor(event.target);
      if (!form) return;
      delete form.dataset.saving;
      updateFormDirtyState(form);
    });
  });
}

function settingsFormFor(target) {
  return target && target.closest ? target.closest('.settings-form') : null;
}

function clearFieldError(event) {
  var group = event.target.closest ? event.target.closest('[data-field]') : null;
  if (!group) return;
  var error = group.querySelector('.form-error');
  if (error) error.textContent = '';
  var input = getFieldInput(group);
  if (input && input.removeAttribute) input.removeAttribute('aria-invalid');
}


function handleGuardTabKeydown(event) {
  var tab = event.target.closest('[data-guard-editor-tab]');
  if (!tab) return;
  var strip = tab.closest('[role="tablist"]');
  if (!strip) return;
  var tabs = Array.prototype.slice.call(strip.querySelectorAll('[data-guard-editor-tab]'));
  var index = tabs.indexOf(tab);
  if (index === -1) return;
  var next = arrowTarget(event.key, tabs, index);
  if (!next) return;
  event.preventDefault();
  if (event.key === ' ' || event.key === 'Enter') {
    tab.click();
  } else {
    next.focus();
  }
}

function testGuardPattern(event) {
  var form = event.target.closest('[data-guard-editor-test]');
  if (!form) return;
  event.preventDefault();
  var editor = form.closest('[data-guard-editor]');
  var candidate = editor && editor.querySelector('[data-guard-editor-add]');
  if (!editor || !candidate) return;
  var guard = editor.dataset.activeGuard;
  var input = form.querySelector('[data-guard-editor-test-input]');
  var mode = form.querySelector('[data-guard-editor-test-mode]');
  var result = editor.querySelector('[data-guard-editor-result]');
  var value = candidate.querySelector('[name="value"]')?.value.trim() || '';
  var payload = { guard: guard, input: input ? input.value : '' };
  if (value) {
    var field = candidate.querySelector('[name="field"]')?.value || '';
    var level = candidate.querySelector('[name="level"]')?.value || 'no_access';
    payload.candidate = { field: field, value: guard === 'file' ? { pattern: value, level: level } : value };
  }
  if (guard === 'file') payload.input = { input: input ? input.value : '', mode: mode ? mode.value : 'write' };

  fetch('/api/config/guards/test', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
    .then(function (response) {
      return response.json().then(function (body) {
        if (!response.ok) throw body;
        return body;
      });
    })
    .then(function (data) {
      if (!result) return;
      result.classList.remove('guard-editor-error');
      var layer = data.evaluatedLayer ? ' [' + data.evaluatedLayer + ']' : '';
      result.textContent = data.verdict.toUpperCase() + layer + (data.reason ? ': ' + data.reason : '');
    })
    .catch(function (error) {
      if (!result) return;
      result.classList.add('guard-editor-error');
      result.textContent = (error.errors && error.errors[0] && error.errors[0].message) || 'Test failed';
    });
}

function initSettingsForm() {
  var grid = document.querySelector('.settings-grid');
  if (!grid || grid.dataset.settingsInit) return;
  grid.dataset.settingsInit = '1';
  var strip = settingsTabStrip();
  var initialTab = (location.hash || '#agent').replace('#', '');
  if (!strip || !strip.querySelector('.tab[href="#' + initialTab + '"]')) initialTab = 'agent';
  activateSettingsTab(initialTab);
  attachSettingsListeners();
  document.querySelectorAll('.settings-form').forEach(updateFormDirtyState);
}

export default class DcSettingsController extends Stimulus.Controller {
  connect() {
    this.element.addEventListener('click', handleSettingsTabClick);
    this.element.addEventListener('keydown', handleSettingsTabKeydown);
    this.element.addEventListener('keydown', handleGuardTabKeydown);
    this.element.addEventListener('submit', testGuardPattern);
    initSettingsForm();
  }

  disconnect() {
    this.element.removeEventListener('click', handleSettingsTabClick);
    this.element.removeEventListener('keydown', handleSettingsTabKeydown);
    this.element.removeEventListener('keydown', handleGuardTabKeydown);
    this.element.removeEventListener('submit', testGuardPattern);
  }
}
