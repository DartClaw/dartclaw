// app.js - DartClaw client-side logic (core)
'use strict';

// Enable View Transitions API for SPA navigation swaps.
htmx.config.globalViewTransitions = true;

const dartclaw = window.dartclaw = window.dartclaw || {};
dartclaw.ui = dartclaw.ui || {};
dartclaw.shell = dartclaw.shell || {};
dartclaw.pages = dartclaw.pages || {};

const pageScriptLoads = new Map();

function runPageHook(hookName, context) {
  Object.values(dartclaw.pages).forEach((page) => {
    if (page && typeof page[hookName] === 'function') {
      page[hookName](context);
    }
  });
}

function pageScriptsForPath(pathname) {
  if (pathname === '/settings' || pathname.startsWith('/settings/')) {
    return ['/static/settings.js'];
  }
  if (pathname === '/memory') {
    return ['/static/memory.js'];
  }
  if (pathname === '/scheduling') {
    return ['/static/scheduling.js'];
  }
  if (pathname.startsWith('/whatsapp/')) {
    return ['/static/whatsapp.js'];
  }
  return [];
}

function loadScript(src) {
  if (!src) return Promise.resolve();
  if (pageScriptLoads.has(src)) {
    return pageScriptLoads.get(src);
  }

  const existing = document.querySelector('script[src="' + CSS.escape(src) + '"]');
  if (existing) {
    const loaded = Promise.resolve();
    pageScriptLoads.set(src, loaded);
    return loaded;
  }

  const promise = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = src;
    script.defer = true;
    script.async = false;
    script.addEventListener('load', () => resolve(), { once: true });
    script.addEventListener('error', () => reject(new Error('Failed to load script: ' + src)), { once: true });
    document.body.appendChild(script);
  });
  pageScriptLoads.set(src, promise);
  return promise;
}

function requestedPathFromSource(source) {
  if (!source) return window.location.pathname;

  const rawPath = source.getAttribute && (
    source.getAttribute('hx-get') ||
    source.getAttribute('href') ||
    source.getAttribute('action')
  );
  if (!rawPath) return window.location.pathname;

  try {
    return new URL(rawPath, window.location.origin).pathname;
  } catch (_) {
    return window.location.pathname;
  }
}

function ensurePageScriptsForPath(pathname) {
  const scripts = pageScriptsForPath(pathname || window.location.pathname);
  if (!scripts.length) {
    return Promise.resolve();
  }
  return scripts.reduce(
    (chain, script) => chain.then(() => loadScript(script)),
    Promise.resolve(),
  );
}

// === Toast notifications ===

const TOAST_DURATION = 4000;
const TOAST_MAX = 5;

function getOrCreateToastContainer() {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    container.className = 'toast-container';
    container.setAttribute('role', 'status');
    container.setAttribute('aria-live', 'polite');
    document.body.appendChild(container);
  }
  return container;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function closeAllCustomSelects(except) {
  document.querySelectorAll('.custom-select[data-open="true"]').forEach((wrapper) => {
    if (except && wrapper === except) return;
    wrapper.dataset.open = 'false';
    const trigger = wrapper.querySelector('.custom-select-trigger');
    if (trigger) trigger.setAttribute('aria-expanded', 'false');
  });
}

function syncCustomSelect(select) {
  if (!select || typeof select._customSelectSync !== 'function') return;
  select._customSelectSync();
}

function enhanceCustomSelect(select) {
  if (!select || select.dataset.customSelectInit) return;
  select.dataset.customSelectInit = '1';

  const wrapper = document.createElement('div');
  wrapper.className = 'custom-select';
  wrapper.dataset.open = 'false';

  select.parentNode.insertBefore(wrapper, select);
  wrapper.appendChild(select);
  select.classList.add('native-select-hidden');
  select.tabIndex = -1;

  const trigger = document.createElement('button');
  trigger.type = 'button';
  trigger.className = 'custom-select-trigger';
  trigger.setAttribute('aria-haspopup', 'listbox');
  trigger.setAttribute('aria-expanded', 'false');

  const label = document.createElement('span');
  label.className = 'custom-select-label';

  const caret = document.createElement('span');
  caret.className = 'custom-select-caret';
  caret.setAttribute('aria-hidden', 'true');

  trigger.append(label, caret);

  const menu = document.createElement('div');
  menu.className = 'custom-select-menu';
  menu.setAttribute('role', 'listbox');

  wrapper.append(trigger, menu);

  function buildOptions() {
    menu.innerHTML = '';
    Array.from(select.options).forEach((option, index) => {
      const optionButton = document.createElement('button');
      optionButton.type = 'button';
      optionButton.className = 'custom-select-option';
      optionButton.setAttribute('role', 'option');
      optionButton.dataset.value = option.value;
      optionButton.dataset.index = String(index);
      optionButton.setAttribute('aria-selected', option.selected ? 'true' : 'false');
      optionButton.disabled = option.disabled;

      const check = document.createElement('span');
      check.className = 'custom-select-check';
      check.setAttribute('aria-hidden', 'true');
      check.textContent = '✓';

      const text = document.createElement('span');
      text.textContent = option.textContent || option.label || '';

      optionButton.append(check, text);
      optionButton.addEventListener('click', () => {
        if (option.disabled) return;
        select.value = option.value;
        select.dispatchEvent(new Event('change', { bubbles: true }));
        syncFromSelect();
        closeAllCustomSelects();
        trigger.focus();
      });

      menu.appendChild(optionButton);
    });
  }

  function syncFromSelect() {
    const selectedOption = select.options[select.selectedIndex] || select.options[0];
    label.textContent = selectedOption ? (selectedOption.textContent || selectedOption.label || '') : '';
    menu.querySelectorAll('.custom-select-option').forEach((optionButton) => {
      const isSelected = optionButton.dataset.value === select.value;
      optionButton.setAttribute('aria-selected', isSelected ? 'true' : 'false');
    });
  }

  function openMenu() {
    closeAllCustomSelects(wrapper);
    wrapper.dataset.open = 'true';
    trigger.setAttribute('aria-expanded', 'true');
  }

  function toggleMenu() {
    const isOpen = wrapper.dataset.open === 'true';
    if (isOpen) {
      closeAllCustomSelects();
    } else {
      openMenu();
    }
  }

  trigger.addEventListener('click', () => toggleMenu());
  trigger.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown' || event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      openMenu();
      const selected = menu.querySelector('.custom-select-option[aria-selected="true"]') || menu.querySelector('.custom-select-option:not([disabled])');
      if (selected) selected.focus();
    }
  });

  menu.addEventListener('keydown', (event) => {
    const options = Array.from(menu.querySelectorAll('.custom-select-option:not([disabled])'));
    const currentIndex = options.indexOf(document.activeElement);
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      const next = options[Math.min(currentIndex + 1, options.length - 1)] || options[0];
      if (next) next.focus();
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      const prev = options[Math.max(currentIndex - 1, 0)] || options[options.length - 1];
      if (prev) prev.focus();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      closeAllCustomSelects();
      trigger.focus();
    }
  });

  select.addEventListener('change', syncFromSelect);
  select._customSelectSync = syncFromSelect;

  buildOptions();
  syncFromSelect();
}

function initCustomSelects(root) {
  (root || document).querySelectorAll('select[data-enhance="custom-select"]').forEach(enhanceCustomSelect);
}

document.addEventListener('click', (event) => {
  if (!event.target.closest('.custom-select')) {
    closeAllCustomSelects();
  }
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeAllCustomSelects();
  }
});

function sanitizeClassToken(value, fallback) {
  const token = String(value ?? '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return token || fallback;
}

function showToast(type, message) {
  const container = getOrCreateToastContainer();
  const toast = document.createElement('div');
  toast.className = 'toast toast-' + type;

  const safeMessage = escapeHtml(message);

  toast.innerHTML =
    '<span>' + safeMessage + '</span>' +
    '<button class="toast-dismiss" aria-label="Dismiss" data-icon="x"></button>';

  toast.querySelector('.toast-dismiss').addEventListener('click', () => removeToast(toast));

  container.appendChild(toast);

  // Enforce max visible — remove oldest first
  while (container.children.length > TOAST_MAX) {
    removeToast(container.firstElementChild);
  }

  setTimeout(() => removeToast(toast), TOAST_DURATION);
}

function removeToast(toast) {
  if (!toast || !toast.parentNode) return;
  if (toast.classList.contains('removing')) return;

  toast.classList.add('removing');
  toast.addEventListener('animationend', () => toast.remove(), { once: true });
}

// === Theme toggle ===

(function restoreTheme() {
  const saved = localStorage.getItem('dartclaw-theme');
  if (saved === 'light') {
    document.documentElement.dataset.theme = 'light';
    const link = document.getElementById('hljs-theme');
    if (link) link.href = '/static/hljs-catppuccin-latte.css';
  }
})();

function applyHljsTheme(isLight) {
  const link = document.getElementById('hljs-theme');
  if (link) {
    link.href = isLight ? '/static/hljs-catppuccin-latte.css' : '/static/hljs-catppuccin-mocha.css';
  }
}

function initThemeToggle() {
  const btn = document.querySelector('.theme-toggle');
  if (!btn || btn.dataset.themeInit) return;
  btn.dataset.themeInit = '1';

  btn.addEventListener('click', () => {
    const html = document.documentElement;
    const next = html.dataset.theme === 'light' ? '' : 'light';
    html.dataset.theme = next;
    localStorage.setItem('dartclaw-theme', next || 'dark');
    applyHljsTheme(next === 'light');
  });
}

// === Sidebar toggle ===

function setSidebarOpen(open) {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;
  sidebar.classList.toggle('open', open);
  const menuToggle = document.querySelector('.menu-toggle');
  if (menuToggle) menuToggle.setAttribute('aria-label', open ? 'Close sidebar' : 'Open sidebar');
  // Scrim visibility is handled via CSS (~) combinator — no JS toggle needed
}

function initSidebar() {
  if (!document.getElementById('sidebar')) return;

  const menuToggle = document.querySelector('.menu-toggle');
  if (menuToggle && !menuToggle.dataset.sidebarInit) {
    menuToggle.dataset.sidebarInit = '1';
    menuToggle.addEventListener('click', () => {
      const sidebar = document.getElementById('sidebar');
      if (!sidebar) return;
      setSidebarOpen(!sidebar.classList.contains('open'));
    });
  }

  const scrim = document.querySelector('.sidebar-scrim');
  if (scrim && !scrim.dataset.sidebarInit) {
    scrim.dataset.sidebarInit = '1';
    scrim.addEventListener('click', () => setSidebarOpen(false));
  }

  initArchiveCollapse();
  syncSidebarNavActiveState();
}

// === Archive collapse toggle with localStorage persistence ===

function initArchiveCollapse() {
  const section = document.querySelector('.sidebar-archive-section');
  if (!section) return;

  const toggle = section.querySelector('.sidebar-archive-toggle');
  const list = section.querySelector('.sidebar-archive-list');
  if (!toggle || !list) return;

  // Force-expand if an archived session is active
  const forceExpand = section.classList.contains('force-expanded');

  // Read stored state (default: collapsed)
  const storageKey = 'dartclaw-sidebar-archived-collapsed';
  const isCollapsed = forceExpand ? false : (localStorage.getItem(storageKey) !== 'false');

  // Apply initial state
  list.style.display = isCollapsed ? 'none' : '';
  toggle.setAttribute('aria-expanded', String(!isCollapsed));
  section.classList.toggle('expanded', !isCollapsed);

  // Bind toggle (idempotent via dataset flag)
  if (!toggle.dataset.archiveInit) {
    toggle.dataset.archiveInit = '1';
    toggle.addEventListener('click', () => {
      const wasExpanded = section.classList.contains('expanded');
      list.style.display = wasExpanded ? 'none' : '';
      section.classList.toggle('expanded', !wasExpanded);
      toggle.setAttribute('aria-expanded', String(!wasExpanded));
      localStorage.setItem(storageKey, String(wasExpanded));
    });
  }
}

function syncSidebarNavActiveState() {
  const currentPath = window.location.pathname.replace(/\/$/, '') || '/';
  if (currentPath === '/' || currentPath.startsWith('/sessions/')) return;

  const sidebarLinks = document.querySelectorAll('.sidebar-nav-item');
  let bestMatchLength = -1;
  const linkPaths = [];

  sidebarLinks.forEach((link) => {
    const linkPath = new URL(link.href, window.location.origin).pathname.replace(/\/$/, '') || '/';
    const matches = linkPath === currentPath || (linkPath !== '/' && currentPath.startsWith(linkPath + '/'));
    linkPaths.push({ link, linkPath, matches });
    if (matches && linkPath.length > bestMatchLength) {
      bestMatchLength = linkPath.length;
    }
  });

  if (bestMatchLength < 0) return;

  linkPaths.forEach(({ link, linkPath, matches }) => {
    link.classList.toggle('active', matches && linkPath.length === bestMatchLength);
  });
}

// === Textarea auto-resize ===

function initTextareaResize() {
  const textarea = document.getElementById('message-input');
  if (!textarea || textarea.dataset.resizeInit) return;
  textarea.dataset.resizeInit = '1';

  textarea.addEventListener('input', () => {
    textarea.style.height = 'auto';
    textarea.style.height = textarea.scrollHeight + 'px';
  });
}

// === Ctrl+Enter / Cmd+Enter submit ===

function initKeyboardSubmit() {
  const textarea = document.getElementById('message-input');
  const form = document.getElementById('chat-form');
  if (!textarea || !form) return;
  if (textarea.dataset.keyboardInit) return;
  textarea.dataset.keyboardInit = '1';

  textarea.addEventListener('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    }
  });
}

// === Markdown rendering pipeline ===

function renderMarkdown() {
  if (typeof marked === 'undefined' || typeof DOMPurify === 'undefined') return;
  document.querySelectorAll('[data-markdown]').forEach((el) => {
    const raw = marked.parse(el.textContent);
    const clean = DOMPurify.sanitize(raw);
    el.innerHTML = clean;
    if (typeof hljs !== 'undefined') {
      el.querySelectorAll('code').forEach((block) => hljs.highlightElement(block));
    }
    el.removeAttribute('data-markdown');
  });
}

// === Auto-scroll ===

function scrollToBottom() {
  const messages = document.querySelector('.messages');
  if (messages) {
    messages.scrollTop = messages.scrollHeight;
  }
}

// === Input state management ===

function disableInput() {
  const input = document.getElementById('message-input');
  const btn = document.getElementById('send-btn');

  if (input) {
    input.disabled = true;
    input.placeholder = 'Agent is responding...';
  }
  if (btn) {
    btn.disabled = true;
  }
}

function enableInput() {
  const input = document.getElementById('message-input');
  const btn = document.getElementById('send-btn');

  if (input) {
    input.disabled = false;
    input.placeholder = 'Type a message...';
  }
  if (btn) {
    btn.disabled = !input || !input.value.trim();
  }
}

// === Send button state (disable when textarea empty) ===

function initSendButtonState() {
  const textarea = document.getElementById('message-input');
  const btn = document.getElementById('send-btn');
  if (!textarea || !btn || btn.dataset.sendInit) return;
  btn.dataset.sendInit = '1';

  function updateSendState() {
    btn.disabled = !textarea.value.trim();
  }

  textarea.addEventListener('input', updateSendState);
  updateSendState(); // set initial state (textarea is empty on load)
}

// === Error banner ===

function showBanner(type, message) {
  const banner = document.createElement('div');
  const safeMessage = String(message)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  banner.className = 'banner banner-' + type;
  banner.innerHTML =
    '<span>' + safeMessage + '</span>' +
    '<button class="dismiss" aria-label="Dismiss" data-icon="x"></button>';

  const chatArea = document.querySelector('.chat-area');
  if (chatArea) {
    chatArea.prepend(banner);
  }

  const dismiss = banner.querySelector('.dismiss');
  if (dismiss) {
    dismiss.addEventListener('click', () => banner.remove());
  }
}

dartclaw.ui.escapeHtml = escapeHtml;
dartclaw.ui.initCustomSelects = initCustomSelects;
dartclaw.ui.sanitizeClassToken = sanitizeClassToken;
dartclaw.ui.showBanner = showBanner;
dartclaw.ui.showToast = showToast;
dartclaw.ui.syncCustomSelect = syncCustomSelect;
dartclaw.shell.renderMarkdown = renderMarkdown;
dartclaw.shell.scrollToBottom = scrollToBottom;

// === Banner dismiss (delegated, for server-rendered banners) ===

document.addEventListener('click', (event) => {
  if (event.target.matches('.dismiss')) {
    const banner = event.target.closest('.banner');
    if (banner) {
      banner.remove();
    }
  }
});

// === Delegated action handler (replaces inline onclick) ===

document.addEventListener('click', (event) => {
  const btn = event.target.closest('[data-action]');
  if (!btn) return;

  const action = btn.dataset.action;

  switch (action) {
    // Scheduling
    case 'toggle-job-form':
      dartclaw.pages.scheduling && dartclaw.pages.scheduling.toggleJobForm && dartclaw.pages.scheduling.toggleJobForm();
      break;
    case 'submit-job-form':
      dartclaw.pages.scheduling &&
        dartclaw.pages.scheduling.submitJobForm &&
        dartclaw.pages.scheduling.submitJobForm(btn.dataset.editName || undefined);
      break;
    case 'edit-job':
      dartclaw.pages.scheduling && dartclaw.pages.scheduling.editJob && dartclaw.pages.scheduling.editJob(btn, btn.dataset.jobName);
      break;
    case 'confirm-delete-job':
      dartclaw.pages.scheduling &&
        dartclaw.pages.scheduling.confirmDeleteJob &&
        dartclaw.pages.scheduling.confirmDeleteJob(btn, btn.dataset.jobName);
      break;
    case 'execute-delete-job':
      dartclaw.pages.scheduling &&
        dartclaw.pages.scheduling.executeDeleteJob &&
        dartclaw.pages.scheduling.executeDeleteJob(btn.dataset.jobName, btn);
      break;
    case 'cancel-delete-job':
      dartclaw.pages.scheduling && dartclaw.pages.scheduling.cancelDeleteJob && dartclaw.pages.scheduling.cancelDeleteJob(btn);
      break;
    case 'toggle-task-form':
      dartclaw.pages.scheduling && dartclaw.pages.scheduling.toggleTaskForm && dartclaw.pages.scheduling.toggleTaskForm();
      break;
    case 'submit-task-form':
      dartclaw.pages.scheduling && dartclaw.pages.scheduling.submitTaskForm && dartclaw.pages.scheduling.submitTaskForm();
      break;
    case 'toggle-scheduled-task':
      dartclaw.pages.scheduling &&
        dartclaw.pages.scheduling.toggleScheduledTask &&
        dartclaw.pages.scheduling.toggleScheduledTask(btn.dataset.taskId);
      break;
    case 'edit-scheduled-task':
      dartclaw.pages.scheduling &&
        dartclaw.pages.scheduling.editScheduledTask &&
        dartclaw.pages.scheduling.editScheduledTask(btn.dataset.taskId);
      break;
    case 'delete-scheduled-task':
      if (btn.dataset.taskId && confirm('Delete scheduled task "' + btn.dataset.taskId + '"?')) {
        dartclaw.pages.scheduling &&
          dartclaw.pages.scheduling.deleteScheduledTask &&
          dartclaw.pages.scheduling.deleteScheduledTask(btn.dataset.taskId);
      }
      break;

    // Memory dashboard
    case 'switch-tab':
      dartclaw.pages.memory && dartclaw.pages.memory.switchTab && dartclaw.pages.memory.switchTab(btn, btn.dataset.tab);
      break;
    case 'toggle-view':
      dartclaw.pages.memory && dartclaw.pages.memory.toggleView && dartclaw.pages.memory.toggleView(btn, btn.dataset.mode);
      break;
    case 'confirm-prune':
      dartclaw.pages.memory && dartclaw.pages.memory.confirmPrune && dartclaw.pages.memory.confirmPrune(btn);
      break;

    // Restart banner
    case 'confirm-restart':
      dartclaw.confirmRestart();
      break;
    case 'dismiss-restart-banner':
      dartclaw.dismissRestartBanner();
      break;
  }
});

document.addEventListener('input', (event) => {
  if (event.target.id === 'job-schedule') {
    dartclaw.pages.scheduling &&
      dartclaw.pages.scheduling.updateCronPreview &&
      dartclaw.pages.scheduling.updateCronPreview(event.target.value);
  } else if (event.target.id === 'task-schedule') {
    dartclaw.pages.scheduling &&
      dartclaw.pages.scheduling.updateTaskCronPreview &&
      dartclaw.pages.scheduling.updateTaskCronPreview(event.target.value);
  }
});

function isChatFormRequest(event) {
  return event.detail && event.detail.elt && event.detail.elt.id === 'chat-form';
}

function extractResponseMessage(xhr) {
  if (!xhr) return 'Request failed';

  const contentType = xhr.getResponseHeader('content-type') || '';
  if (contentType.includes('application/json')) {
    try {
      const parsed = JSON.parse(xhr.responseText || '{}');
      const error = parsed.error || {};
      return error.message || 'Request failed';
    } catch (_) {
      return 'Request failed';
    }
  }

  return xhr.statusText || 'Request failed';
}

// === HTMX request lifecycle ===

function initHtmxRequestLifecycle() {
  document.body.addEventListener('htmx:beforeRequest', (event) => {
    if (!isChatFormRequest(event)) return;
    disableInput();
  });

  document.body.addEventListener('htmx:afterRequest', (event) => {
    if (!isChatFormRequest(event)) return;

    if (event.detail.successful) {
      return;
    }

    enableInput();
    showBanner('error', extractResponseMessage(event.detail.xhr));
  });
}

function loadMessages(sessionId) {
  const messages = document.getElementById('messages');
  return htmx.ajax('GET', '/sessions/' + sessionId + '/messages-html', {
    target: '#messages',
    swap: 'innerHTML',
    source: messages,
  });
}

function updateMessagePagination(xhr) {
  const chatArea = document.querySelector('.chat-area');
  if (!chatArea || !xhr) return;

  const earliestCursor = xhr.getResponseHeader('x-dartclaw-earliest-cursor');
  if (earliestCursor) {
    chatArea.dataset.earliestCursor = earliestCursor;
  } else {
    delete chatArea.dataset.earliestCursor;
  }

  const hasEarlierMessages = xhr.getResponseHeader('x-dartclaw-has-earlier-messages') === 'true';
  const button = document.querySelector('[data-load-earlier]');
  if (!button) return;

  button.hidden = !hasEarlierMessages;
  if (hasEarlierMessages) {
    button.removeAttribute('hidden');
  } else {
    button.setAttribute('hidden', 'hidden');
  }
}

function initLoadEarlierMessages() {
  document.addEventListener('click', (event) => {
    const button = event.target.closest('[data-load-earlier]');
    if (!button) return;
    event.preventDefault();

    const chatArea = document.querySelector('.chat-area');
    const sessionId = chatArea && chatArea.dataset.sessionId;
    const earliestCursor = chatArea && chatArea.dataset.earliestCursor;
    if (!sessionId || !earliestCursor) return;

    button.disabled = true;
    htmx.ajax('GET', '/sessions/' + encodeURIComponent(sessionId) + '/messages-html?before=' + earliestCursor, {
      target: '#messages',
      swap: 'afterbegin',
      source: button,
    });
  });

  document.body.addEventListener('htmx:afterRequest', (event) => {
    const elt = event.detail && event.detail.elt;
    if (!elt) return;

    const isMessagesReload = elt.id === 'messages';
    const isLoadEarlier = elt.matches && elt.matches('[data-load-earlier]');
    if (!isMessagesReload && !isLoadEarlier) return;

    if (isLoadEarlier) {
      elt.disabled = false;
    }

    if (!event.detail.successful) {
      if (isLoadEarlier) {
        showBanner('error', extractResponseMessage(event.detail.xhr));
      }
      return;
    }

    updateMessagePagination(event.detail.xhr);
  });
}

// === Session CRUD ===

function initSessionCreate() {
  document.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-action="create-session"]');
    if (!btn) return;
    event.preventDefault();

    fetch('/api/sessions', { method: 'POST' })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to create session');
        return res.json();
      })
      .then((data) => {
        window.location.href = '/sessions/' + data.id;
      })
      .catch((err) => {
        showToast('error', err.message || 'Failed to create session');
      });
  });
}

function initSessionDelete() {
  document.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-action="delete-session"]');
    if (!btn) return;
    event.preventDefault();
    event.stopPropagation(); // prevent <a> navigation on sidebar items

    const sessionId = btn.dataset.sessionId;
    if (!sessionId) return;

    if (!confirm('Permanently delete this chat and all its messages?')) return;

    fetch('/api/sessions/' + encodeURIComponent(sessionId), { method: 'DELETE' })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to delete session');
        window.location.href = '/';
      })
      .catch((err) => {
        showToast('error', err.message || 'Failed to delete session');
      });
  });
}

function currentSessionPathId() {
  const match = window.location.pathname.match(/^\/sessions\/([^/]+)$/);
  return match ? decodeURIComponent(match[1]) : null;
}

function readHtmxErrorMessage(xhr, fallbackMessage) {
  const contentType = xhr.getResponseHeader('content-type') || '';
  if (contentType.includes('application/json')) {
    try {
      const parsed = JSON.parse(xhr.responseText || '{}');
      return parsed.error?.message || fallbackMessage;
    } catch (_) {
      return fallbackMessage;
    }
  }
  return fallbackMessage;
}

function bindHtmxRequestErrors(source, fallbackMessage) {
  let cleanedUp = false;

  function cleanup() {
    if (cleanedUp) return;
    cleanedUp = true;
    document.body.removeEventListener('htmx:responseError', handleResponseError);
    document.body.removeEventListener('htmx:sendError', handleSendError);
  }

  function handleResponseError(event) {
    if (!event.detail || event.detail.elt !== source) return;
    cleanup();
    showToast('error', readHtmxErrorMessage(event.detail.xhr, fallbackMessage));
  }

  function handleSendError(event) {
    if (!event.detail || event.detail.elt !== source) return;
    cleanup();
    showToast('error', fallbackMessage);
  }

  document.body.addEventListener('htmx:responseError', handleResponseError);
  document.body.addEventListener('htmx:sendError', handleSendError);
  return cleanup;
}

function initSessionArchive() {
  document.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-action="archive-session"]');
    if (!btn) return;
    event.preventDefault();
    event.stopPropagation();

    const sessionId = btn.dataset.sessionId;
    if (!sessionId) return;

    const sidebar = document.getElementById('sidebar');
    const wasSidebarOpen = !!(sidebar && sidebar.classList.contains('open'));
    const activeSessionId = currentSessionPathId();
    const headers = activeSessionId ? { 'X-Dartclaw-Active-Session-Id': activeSessionId } : {};
    const cleanup = bindHtmxRequestErrors(btn, 'Failed to archive chat');
    const request = htmx.ajax('POST', '/api/sessions/' + encodeURIComponent(sessionId) + '/archive', {
      source: btn,
      target: '#sidebar',
      swap: 'none',
      headers,
    });

    if (request && typeof request.then === 'function') {
      request.then(() => {
        if (wasSidebarOpen) {
          setSidebarOpen(true);
        }
        cleanup();
      }, cleanup);
    }
  });
}

function initResumeArchive() {
  document.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-action="resume-archive"]');
    if (!btn) return;
    event.preventDefault();

    const sessionId = btn.dataset.sessionId;
    if (!sessionId) return;

    fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/resume', { method: 'POST' })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to resume session');
        return res.json();
      })
      .then(() => {
        window.location.reload();
      })
      .catch((err) => {
        showToast('error', err.message || 'Failed to resume session');
      });
  });
}

// === Inline rename ===

function initInlineRename() {
  const input = document.querySelector('.topbar .session-title[type="text"]');
  if (!input || input.dataset.renameInit) return;
  input.dataset.renameInit = '1';

  function commitRename() {
    const newTitle = input.value.trim();
    const original = input.dataset.originalTitle;
    const sessionId = input.dataset.sessionId;

    if (!newTitle || newTitle === original) {
      input.value = original;
      return;
    }

    fetch('/api/sessions/' + encodeURIComponent(sessionId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: newTitle }),
    })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to rename session');
        input.dataset.originalTitle = newTitle;
        const chatArea = document.querySelector('.chat-area');
        if (chatArea) {
          // Manual rename means this session now has a user-defined title.
          chatArea.dataset.hasTitle = 'true';
        }
        // Update sidebar item text and browser tab title
        const sidebarItem = document.querySelector(
          '.session-item-link[href*="' + CSS.escape(sessionId) + '"] .session-item-title',
        );
        if (sidebarItem) sidebarItem.textContent = newTitle;
        document.title = newTitle + ' - ' + (document.body.dataset.appName || 'DartClaw');
        showToast('success', 'Session renamed');
      })
      .catch((err) => {
        input.value = original;
        showToast('error', err.message || 'Failed to rename session');
      });
  }

  input.addEventListener('blur', commitRename);

  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      input.blur();
    } else if (event.key === 'Escape') {
      input.value = input.dataset.originalTitle;
      input.blur();
    }
  });
}

// === HTMX SSE lifecycle ===

function finalizeTurn() {
  document.body.classList.remove('streaming');

  const content = document.getElementById('streaming-content');
  if (content) {
    content.classList.remove('streaming');
  }

  // Clear and reset textarea.
  const textarea = document.getElementById('message-input');
  if (textarea) {
    textarea.value = '';
    textarea.style.height = 'auto';
  }

  enableInput();

  const chatArea = document.querySelector('.chat-area');
  const sessionId = chatArea && chatArea.dataset.sessionId;
  if (!sessionId) return;

  loadMessages(sessionId)
    .then(() => {
      renderMarkdown();
      scrollToBottom();

      // Auto-title untitled sessions from first user message.
      if (chatArea && chatArea.dataset.hasTitle !== 'true') {
        const firstUserMsg = document.querySelector('#messages .msg-user .msg-content');
        if (firstUserMsg) {
          let title = (firstUserMsg.textContent || '').trim();
          if (title.length > 50) {
            title = title.substring(0, 50).replace(/\s+\S*$/, '');
          }
          if (title) {
            fetch('/api/sessions/' + encodeURIComponent(sessionId), {
              method: 'PATCH',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ title: title }),
            })
              .then((res) => {
                if (!res.ok) return;
                chatArea.dataset.hasTitle = 'true';
                const titleInput = document.querySelector('.topbar .session-title[type="text"]');
                if (titleInput) {
                  titleInput.value = title;
                  titleInput.dataset.originalTitle = title;
                }
                const sidebarItem = document.querySelector('.session-item.active .session-item-title');
                if (sidebarItem) sidebarItem.textContent = title;
              })
              .catch(() => {}); // silent fail for auto-title
          }
        }
      }
    })
    .catch(() => {
      showToast('error', 'Failed to refresh messages');
    });
}

function initSseLifecycle() {
  // Detect streaming start when #streaming-msg appears via form submit swap into #messages.
  document.body.addEventListener('htmx:afterSwap', (event) => {
    const target = event.detail && event.detail.target;
    if (!target || target.id !== 'messages') return;

    const streamingMsg = document.getElementById('streaming-msg');
    if (!streamingMsg) return;

    document.body.classList.add('streaming');
  });

  // Auto-scroll on SSE content swaps (delta text and tool indicators).
  document.body.addEventListener('htmx:sseMessage', () => {
    scrollToBottom();
  });

  // Full post-done orchestration when HTMX SSE extension closes the EventSource.
  document.body.addEventListener('htmx:sseClose', () => {
    finalizeTurn();
  });

}

// === Namespaced globals for HTMX event handlers ===

dartclaw.handleTurnError = function(event) {
  // Extract error text from the hidden swap target before finalizeTurn clears the DOM.
  const container = document.getElementById('turn-error-target');
  const turnError = container && container.querySelector('.turn-error');
  const message = turnError ? turnError.textContent : 'Stream error';
  if (container) container.innerHTML = '';

  finalizeTurn();
  showBanner('error', message);
};

// === SPA content re-initialization after HTMX swap ===

function initAfterSwapReinit() {
  document.body.addEventListener('htmx:afterSwap', (event) => {
    const target = event.detail && event.detail.target;
    const source = event.detail && event.detail.elt;
    const isLoadEarlier = source && source.matches && source.matches('[data-load-earlier]');
    renderMarkdown();
    if (!isLoadEarlier) {
      scrollToBottom();
    }
    initThemeToggle();
    initSidebar();
    initTextareaResize();
    initKeyboardSubmit();
    initSendButtonState();
    initInlineRename();
    const requestedPath = target && target.id === 'main-content'
      ? requestedPathFromSource(source)
      : window.location.pathname;
    ensurePageScriptsForPath(requestedPath)
      .catch((error) => {
        showToast('error', error.message || 'Failed to load page scripts');
      })
      .finally(() => {
        runPageHook('onAfterSwap', { target, source, isLoadEarlier });
        if (target && target.id === 'main-content') {
          target.focus({ preventScroll: true });
        }
      });
  });
}

// === HTMX history restore re-init ===

function initHistoryRestore() {
  document.body.addEventListener('htmx:historyCacheMissLoad', () => {
    renderMarkdown();
    scrollToBottom();
  });

  document.body.addEventListener('htmx:historyRestore', () => {
    renderMarkdown();
    scrollToBottom();
    initThemeToggle();
    initSidebar();
    initTextareaResize();
    initKeyboardSubmit();
    initSendButtonState();
    initInlineRename();
    ensurePageScriptsForPath(window.location.pathname)
      .catch((error) => {
        showToast('error', error.message || 'Failed to load page scripts');
      })
      .finally(() => {
        runPageHook('onHistoryRestore');
        const mainContent = document.getElementById('main-content');
        if (mainContent) {
          mainContent.focus({ preventScroll: true });
        }
      });
  });
}

// === Audit table row expand/collapse ===

document.addEventListener('click', (event) => {
  const row = event.target.closest('.audit-row');
  if (!row) return;

  const detailRow = row.nextElementSibling;
  if (!detailRow || !detailRow.classList.contains('audit-detail-row')) return;

  const isHidden = detailRow.style.display === 'none' || !detailRow.style.display;
  detailRow.style.display = isHidden ? 'table-row' : 'none';
  row.classList.toggle('expanded', isHidden);
  row.setAttribute('aria-expanded', String(isHidden));
});

document.addEventListener('keydown', (event) => {
  if (event.key !== 'Enter' && event.key !== ' ') return;
  const row = event.target.closest('.audit-row');
  if (!row) return;
  event.preventDefault();

  const detailRow = row.nextElementSibling;
  if (!detailRow || !detailRow.classList.contains('audit-detail-row')) return;

  const isHidden = detailRow.style.display === 'none' || !detailRow.style.display;
  detailRow.style.display = isHidden ? 'table-row' : 'none';
  row.classList.toggle('expanded', isHidden);
  row.setAttribute('aria-expanded', String(isHidden));
});

// === Graceful Restart ===

let globalEventSource = null;
let restartPollTimer = null;
let restartPollStart = null;
const RESTART_POLL_INTERVAL = 2000;
const RESTART_POLL_TIMEOUT = 90000;

function connectGlobalEvents() {
  if (globalEventSource) return;
  const token = new URLSearchParams(window.location.search).get('token');
  const url = '/api/events' + (token ? '?token=' + encodeURIComponent(token) : '');
  globalEventSource = new EventSource(url);

  globalEventSource.addEventListener('server_restart', () => {
    showRestartOverlay();
  });

  globalEventSource.addEventListener('context_warning', function(event) {
    try {
      var data = JSON.parse(event.data);
      var currentSessionId = getCurrentSessionId();
      if (!currentSessionId) return;
      if (data.sessionId !== currentSessionId) return;
      if (document.getElementById('context-warning-banner')) return;

      var banner = document.createElement('div');
      banner.id = 'context-warning-banner';
      banner.className = 'banner banner-warning';
      banner.setAttribute('role', 'status');
      banner.setAttribute('aria-live', 'polite');

      var safeMessage = String(data.message || 'Context window running low.')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');

      banner.innerHTML =
        '<span>' + safeMessage + '</span>' +
        '<button class="dismiss" aria-label="Dismiss" data-icon="x"></button>';

      var chatArea = document.querySelector('.chat-area');
      if (chatArea) { chatArea.prepend(banner); }
    } catch (_) {}
  });

  globalEventSource.onerror = () => {
    if (document.getElementById('restart-overlay')) {
      startRestartPolling();
    }
  };
}

function getCurrentSessionId() {
  const match = window.location.pathname.match(/^\/sessions\/([^/]+)/);
  return match ? match[1] : null;
}

function showRestartOverlay() {
  if (document.getElementById('restart-overlay')) return;

  const overlay = document.createElement('div');
  overlay.id = 'restart-overlay';
  overlay.className = 'restart-overlay';
  overlay.setAttribute('role', 'status');
  overlay.setAttribute('aria-live', 'assertive');
  overlay.innerHTML = `
    <div class="restart-overlay-content">
      <div class="restart-spinner"></div>
      <h2>Server is restarting...</h2>
      <p id="restart-status">Waiting for server to come back online</p>
    </div>
  `;
  document.body.appendChild(overlay);

  startRestartPolling();
}

function startRestartPolling() {
  if (restartPollTimer) return;
  restartPollStart = Date.now();

  restartPollTimer = setInterval(async () => {
    const elapsed = Date.now() - restartPollStart;

    if (elapsed > RESTART_POLL_TIMEOUT) {
      clearInterval(restartPollTimer);
      restartPollTimer = null;
      const status = document.getElementById('restart-status');
      if (status) {
        status.textContent = 'Server did not restart within 90s. Please check the server manually.';
      }
      return;
    }

    try {
      const resp = await fetch('/health');
      if (resp.ok) {
        clearInterval(restartPollTimer);
        restartPollTimer = null;
        window.location.reload();
      }
    } catch (_) {
      // Server still down
    }
  }, RESTART_POLL_INTERVAL);
}

window.dartclaw.confirmRestart = function() {
  if (!confirm('Restart ' + (document.body.dataset.appName || 'DartClaw') + '? Active turns will complete first.')) return;

  const token = new URLSearchParams(window.location.search).get('token');
  fetch('/api/system/restart' + (token ? '?token=' + encodeURIComponent(token) : ''), {
    method: 'POST',
  }).then(resp => {
    if (resp.ok) {
      showRestartOverlay();
    } else {
      resp.json().then(data => {
        alert('Restart failed: ' + (data.error?.message || 'Unknown error'));
      }).catch(() => alert('Restart failed'));
    }
  }).catch(() => alert('Failed to reach server'));
};

// Restart banner dismissed flag — shared via dartclaw namespace for cross-script access.
dartclaw._restartBannerDismissed = false;

window.dartclaw.dismissRestartBanner = function() {
  const banner = document.getElementById('restart-banner');
  if (banner) banner.style.display = 'none';
  dartclaw._restartBannerDismissed = true;
};

function initRestartBanner() {
  // Flag is always false on fresh page load/reload — banner reappears if pending.
  connectGlobalEvents();
}

function getApiToken() {
  return new URLSearchParams(window.location.search).get('token');
}

function apiQs() {
  const token = getApiToken();
  return token ? '?token=' + encodeURIComponent(token) : '';
}

dartclaw.shell.apiQs = apiQs;
dartclaw.shell.getApiToken = getApiToken;

// === TIMELINE AUTO-SCROLL ===

function scrollTimelineToBottom(container) {
  if (container) container.scrollTop = container.scrollHeight;
}

function applyTimelineAutoScroll() {
  const container = document.querySelector('[data-auto-scroll="true"]');
  scrollTimelineToBottom(container);
}

document.addEventListener('htmx:afterSettle', applyTimelineAutoScroll);
applyTimelineAutoScroll();

document.addEventListener('DOMContentLoaded', () => {
  initThemeToggle();
  initSidebar();
  initTextareaResize();
  initKeyboardSubmit();
  initSendButtonState();
  initHtmxRequestLifecycle();
  initSseLifecycle();
  initAfterSwapReinit();
  initHistoryRestore();
  initSessionCreate();
  initSessionArchive();
  initSessionDelete();
  initResumeArchive();
  initInlineRename();
  initLoadEarlierMessages();
  initRestartBanner();
  ensurePageScriptsForPath(window.location.pathname)
    .catch((error) => {
      showToast('error', error.message || 'Failed to load page scripts');
    })
    .finally(() => {
      runPageHook('onLoad');
      renderMarkdown();
      scrollToBottom();
    });
});

document.body.addEventListener('htmx:beforeSwap', (event) => {
  runPageHook('onBeforeSwap', event);
});
