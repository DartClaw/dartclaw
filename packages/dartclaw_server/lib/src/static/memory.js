// memory.js - DartClaw memory dashboard logic
'use strict';

// === Memory dashboard: auto-load default tab on first render ===

function initMemoryDefaultTab() {
  var activeTab = document.querySelector('.tab-btn.active[data-action="switch-tab"][data-tab]');
  if (!activeTab) return;
  var tabId = activeTab.dataset.tab;
  var panel = document.getElementById(tabId);
  if (!panel) return;
  var preview = panel.querySelector('.memory-preview');
  if (preview && !preview.dataset.loaded && !preview.dataset.loading) {
    switchMemoryTab(activeTab, tabId);
  }
}

// === Memory dashboard: tab switching ===

function switchMemoryTab(btn, tabId) {
  var card = btn.closest('.card');
  if (!card) return;

  card.querySelectorAll('.tab-btn').forEach(function (t) { t.classList.remove('active'); });
  card.querySelectorAll('.tab-btn').forEach(function (t) { t.setAttribute('aria-selected', 'false'); });
  btn.classList.add('active');
  btn.setAttribute('aria-selected', 'true');
  card.querySelectorAll('.tab-panel').forEach(function (p) { p.classList.remove('active'); });
  var panel = card.querySelector('#' + tabId);
  if (panel) panel.classList.add('active');

  // Lazy load file content if not already loaded
  if (!panel) return;
  var preview = panel.querySelector('.memory-preview');
  if (preview && !preview.dataset.loaded && !preview.dataset.loading) {
    var fileName = preview.dataset.file;
    if (fileName) {
      preview.dataset.loading = '1';
      preview.textContent = 'Loading...';
      fetch('/api/memory/files/' + encodeURIComponent(fileName))
        .then(function (r) { return r.ok ? r.text() : Promise.reject('Not found'); })
        .then(function (text) {
          preview.dataset.rawContent = text;
          preview.dataset.loaded = '1';
          delete preview.dataset.loading;
          applyMemoryViewMode(preview);
        })
        .catch(function () {
          delete preview.dataset.loading;
          preview.textContent = 'Failed to load file content.';
        });
    }
  }
}

// === Memory dashboard: raw/rendered toggle ===

function applyMemoryViewMode(preview) {
  var rawContent = preview.dataset.rawContent;
  if (rawContent == null) return;
  if (rawContent === '') {
    preview.textContent = 'File is empty — no entries yet.';
    return;
  }
  var mode = localStorage.getItem('dartclaw-memory-view') || 'raw';
  if (mode === 'rendered' && window.marked) {
    preview.innerHTML = DOMPurify.sanitize(marked.parse(rawContent));
  } else {
    preview.textContent = rawContent;
  }
}

function toggleMemoryView(btn, mode) {
  var group = btn.closest('.toggle-btn-group');
  if (group) {
    group.querySelectorAll('.toggle-btn').forEach(function (b) { b.classList.remove('active'); });
  }
  btn.classList.add('active');
  localStorage.setItem('dartclaw-memory-view', mode);
  // Apply mode to all already-loaded memory previews.
  document.querySelectorAll('.memory-preview[data-loaded]').forEach(applyMemoryViewMode);
}

// === Memory dashboard: prune confirmation ===

function confirmPrune(btn) {
  if (btn.dataset.confirming) {
    btn.textContent = 'Pruning...';
    btn.disabled = true;
    delete btn.dataset.confirming;
    fetch('/api/memory/prune', { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function () {
        btn.textContent = 'Done!';
        btn.style.color = 'var(--success)';
        var content = document.getElementById('memory-content');
        if (content) htmx.ajax('GET', '/memory/content', { target: '#memory-content', swap: 'innerHTML', select: '#memory-inner' });
        setTimeout(function () {
          btn.textContent = 'Prune Now';
          btn.style.color = '';
          btn.disabled = false;
        }, 2000);
      })
      .catch(function () {
        btn.textContent = 'Failed';
        btn.style.color = 'var(--error)';
        setTimeout(function () {
          btn.textContent = 'Prune Now';
          btn.style.color = '';
          btn.disabled = false;
        }, 2000);
      });
    return;
  }
  btn.dataset.confirming = '1';
  btn.textContent = 'Confirm Prune?';
  btn.style.color = 'var(--warning)';
  setTimeout(function () {
    if (btn.dataset.confirming) {
      btn.textContent = 'Prune Now';
      btn.style.color = '';
      delete btn.dataset.confirming;
    }
  }, 4000);
}

// === Memory dashboard: view toggle init ===

function initMemoryViewToggle() {
  var memView = localStorage.getItem('dartclaw-memory-view');
  if (memView === 'rendered') {
    document.querySelectorAll('.toggle-btn[data-mode="rendered"]').forEach(function (b) {
      b.classList.add('active');
      if (b.previousElementSibling) b.previousElementSibling.classList.remove('active');
    });
  }
}
