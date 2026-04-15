// app.js - DartClaw client-side logic (core)
'use strict';

// Enable View Transitions API for SPA navigation swaps.
htmx.config.globalViewTransitions = true;

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
      typeof toggleJobForm === 'function' && toggleJobForm();
      break;
    case 'submit-job-form':
      typeof submitJobForm === 'function' && submitJobForm(btn.dataset.editName || undefined);
      break;
    case 'edit-job':
      typeof editJob === 'function' && editJob(btn, btn.dataset.jobName);
      break;
    case 'confirm-delete-job':
      typeof confirmDeleteJob === 'function' && confirmDeleteJob(btn, btn.dataset.jobName);
      break;
    case 'execute-delete-job':
      typeof executeDeleteJob === 'function' && executeDeleteJob(btn.dataset.jobName, btn);
      break;
    case 'cancel-delete-job':
      typeof cancelDeleteJob === 'function' && cancelDeleteJob(btn);
      break;

    // Memory dashboard
    case 'switch-tab':
      typeof switchMemoryTab === 'function' && switchMemoryTab(btn, btn.dataset.tab);
      break;
    case 'toggle-view':
      typeof toggleMemoryView === 'function' && toggleMemoryView(btn, btn.dataset.mode);
      break;
    case 'confirm-prune':
      typeof confirmPrune === 'function' && confirmPrune(btn);
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
    typeof updateCronPreview === 'function' && updateCronPreview(event.target.value);
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

window.dartclaw = window.dartclaw || {};

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
    typeof initSettingsForm === 'function' && initSettingsForm();
    typeof initChannelDetail === 'function' && initChannelDetail();
    typeof initPairingPolling === 'function' && initPairingPolling();
    typeof initQrFallback === 'function' && initQrFallback();
    typeof initQrCountdown === 'function' && initQrCountdown();
    typeof initMemoryViewToggle === 'function' && initMemoryViewToggle();
    typeof initMemoryDefaultTab === 'function' && initMemoryDefaultTab();
    if (target && target.id === 'main-content') {
      refreshSidebarTaskState();
    } else {
      restoreTaskBadge();
      renderRunningSidebar(cachedActiveTasks);
      renderWorkflowSidebar(cachedActiveWorkflows);
    }
    resetWorkflowNotificationIfOnWorkflowsPage();
    initTaskElapsedTimers();
    initTaskListControls();
    initTaskReviewActions();
    initTaskStartActions();
    initTaskCancelActions();
    initTaskDialogTabs();
    initNewTaskForm();
    initTaskDetailRefresh();
    if (target && target.id === 'main-content') {
      target.focus({ preventScroll: true });
    }
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
    refreshSidebarTaskState();
    resetWorkflowNotificationIfOnWorkflowsPage();
    initThemeToggle();
    initSidebar();
    initTextareaResize();
    initKeyboardSubmit();
    initSendButtonState();
    initInlineRename();
    typeof initSettingsForm === 'function' && initSettingsForm();
    typeof initChannelDetail === 'function' && initChannelDetail();
    typeof initPairingPolling === 'function' && initPairingPolling();
    typeof initQrFallback === 'function' && initQrFallback();
    typeof initQrCountdown === 'function' && initQrCountdown();
    typeof initMemoryViewToggle === 'function' && initMemoryViewToggle();
    typeof initMemoryDefaultTab === 'function' && initMemoryDefaultTab();
    initTaskElapsedTimers();
    initTaskListControls();
    initTaskReviewActions();
    initTaskStartActions();
    initTaskCancelActions();
    initTaskDialogTabs();
    initNewTaskForm();
    initTaskDetailRefresh();
    const mainContent = document.getElementById('main-content');
    if (mainContent) {
      mainContent.focus({ preventScroll: true });
    }
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

// === SCHEDULING PAGE: JOB + TASK CRUD ===

function initSchedulingPage() {
  // Delegated click handler for all scheduling data-action buttons
  document.addEventListener('click', function(e) {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const action = btn.getAttribute('data-action');

    // --- Scheduled task form ---
    if (action === 'toggle-task-form') {
      const form = document.getElementById('task-form');
      if (form) {
        const visible = form.style.display !== 'none';
        form.style.display = visible ? 'none' : '';
        if (!visible) resetTaskForm();
      }
    }
    if (action === 'submit-task-form') {
      submitTaskForm();
    }
    if (action === 'toggle-scheduled-task') {
      const taskId = btn.getAttribute('data-task-id');
      if (taskId) toggleScheduledTask(taskId);
    }
    if (action === 'edit-scheduled-task') {
      const taskId = btn.getAttribute('data-task-id');
      if (taskId) editScheduledTask(taskId);
    }
    if (action === 'delete-scheduled-task') {
      const taskId = btn.getAttribute('data-task-id');
      if (taskId && confirm('Delete scheduled task "' + taskId + '"?')) deleteScheduledTask(taskId);
    }
  });
}

function getApiToken() {
  return new URLSearchParams(window.location.search).get('token');
}

function apiQs() {
  const token = getApiToken();
  return token ? '?token=' + encodeURIComponent(token) : '';
}

// --- Job CRUD ---

async function submitJobForm() {
  const name = document.getElementById('job-name')?.value?.trim();
  const schedule = document.getElementById('job-schedule')?.value?.trim();
  const prompt = document.getElementById('job-prompt')?.value?.trim();
  const deliveryEl = document.querySelector('input[name="delivery"]:checked');
  const delivery = deliveryEl ? deliveryEl.value : 'none';

  if (!name || !schedule || !prompt) {
    showToast('error', 'Name, schedule, and prompt are required');
    return;
  }

  try {
    const resp = await fetch('/api/scheduling/jobs' + apiQs(), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, schedule, prompt, delivery }),
    });
    if (resp.ok || resp.status === 201) {
      showToast('success', 'Job created — restart required');
      setTimeout(() => window.location.reload(), 1000);
    } else {
      const data = await resp.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Failed to create job');
    }
  } catch (_) {
    showToast('error', 'Failed to reach server');
  }
}

async function editJob(name) {
  const newSchedule = prompt('New schedule for "' + name + '":');
  if (!newSchedule) return;

  try {
    const resp = await fetch('/api/scheduling/jobs/' + encodeURIComponent(name) + apiQs(), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ schedule: newSchedule }),
    });
    if (resp.ok) {
      showToast('success', 'Job updated — restart required');
      setTimeout(() => window.location.reload(), 1000);
    } else {
      const data = await resp.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Failed to update job');
    }
  } catch (_) {
    showToast('error', 'Failed to reach server');
  }
}

async function deleteJob(name) {
  try {
    const resp = await fetch('/api/scheduling/jobs/' + encodeURIComponent(name) + apiQs(), {
      method: 'DELETE',
    });
    if (resp.ok) {
      showToast('success', 'Job deleted — restart required');
      setTimeout(() => window.location.reload(), 1000);
    } else {
      const data = await resp.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Failed to delete job');
    }
  } catch (_) {
    showToast('error', 'Failed to reach server');
  }
}

// --- Scheduled Task CRUD ---

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
    showToast('error', 'ID, schedule, title, description, and type are required');
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

    const resp = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    if (resp.ok || resp.status === 201) {
      showToast('success', (isEdit ? 'Task updated' : 'Task created') + ' — restart required');
      setTimeout(() => window.location.reload(), 1000);
    } else {
      const data = await resp.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Failed to save scheduled task');
    }
  } catch (_) {
    showToast('error', 'Failed to reach server');
  }
}

async function toggleScheduledTask(taskId) {
  // Fetch current config to find the task's current enabled state
  try {
    const configResp = await fetch('/api/config' + apiQs());
    if (!configResp.ok) {
      showToast('error', 'Failed to read config');
      return;
    }
    const config = await configResp.json();
    const jobs = config.scheduling?.jobs || [];
    const job = jobs.find(function(j) { return j.type === 'task' && j.id === taskId; });
    if (!job) {
      showToast('error', 'Task not found');
      return;
    }

    const resp = await fetch('/api/scheduling/tasks/' + encodeURIComponent(taskId) + apiQs(), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: !job.enabled }),
    });
    if (resp.ok) {
      showToast('success', 'Task ' + (!job.enabled ? 'enabled' : 'disabled') + ' — restart required');
      setTimeout(() => window.location.reload(), 1000);
    } else {
      const data = await resp.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Failed to toggle task');
    }
  } catch (_) {
    showToast('error', 'Failed to reach server');
  }
}

async function editScheduledTask(taskId) {
  // Fetch current config to pre-populate the form
  try {
    const configResp = await fetch('/api/config' + apiQs());
    if (!configResp.ok) {
      showToast('error', 'Failed to read config');
      return;
    }
    const config = await configResp.json();
    const jobs = config.scheduling?.jobs || [];
    const job = jobs.find(function(j) { return j.type === 'task' && j.id === taskId; });
    if (!job) {
      showToast('error', 'Task not found in config');
      return;
    }
    const taskDef = job.task || {};

    // Show and populate form
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
  } catch (_) {
    showToast('error', 'Failed to reach server');
  }
}

async function deleteScheduledTask(taskId) {
  try {
    const resp = await fetch('/api/scheduling/tasks/' + encodeURIComponent(taskId) + apiQs(), {
      method: 'DELETE',
    });
    if (resp.ok) {
      showToast('success', 'Scheduled task deleted — restart required');
      setTimeout(() => window.location.reload(), 1000);
    } else {
      const data = await resp.json().catch(() => ({}));
      showToast('error', data.error?.message || 'Failed to delete scheduled task');
    }
  } catch (_) {
    showToast('error', 'Failed to reach server');
  }
}

// === Init ===

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
  typeof initMemoryViewToggle === 'function' && initMemoryViewToggle();
  typeof initMemoryDefaultTab === 'function' && initMemoryDefaultTab();
  typeof initSettingsForm === 'function' && initSettingsForm();
  typeof initChannelDetail === 'function' && initChannelDetail();
  typeof initPairingPolling === 'function' && initPairingPolling();
  initSchedulingPage();
  initRestartBanner();
  typeof initQrFallback === 'function' && initQrFallback();
  typeof initQrCountdown === 'function' && initQrCountdown();
  initTaskSse();
  initTaskElapsedTimers();
  initTaskListControls();
  initTaskReviewActions();
  initTaskStartActions();
  initTaskCancelActions();
  initTaskDialogTabs();
  initNewTaskForm();
  initTaskDetailRefresh();
  initProjectHandlers();
  initWorkflowDetailSSE();
  renderMarkdown();
  scrollToBottom();
});

// === TASK SSE + BADGE ===

let taskEventSource = null;
let latestTaskReviewCount = null;
let cachedActiveTasks = [];
let cachedActiveWorkflows = [];
let workflowNotificationCount = 0;
let taskElapsedTimer = null;
let taskDetailRefreshTimer = null;

function renderRunningSidebar(tasks) {
  cachedActiveTasks = Array.isArray(tasks) ? tasks : [];

  const existing = document.getElementById('sidebar-running');
  if (!cachedActiveTasks.length) {
    existing && existing.remove();
    return;
  }

  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;

  const chatsLabel = Array.from(sidebar.querySelectorAll('.sidebar-section-label'))
    .find((element) => element.textContent.trim() === 'Chats');
  if (!chatsLabel || !chatsLabel.parentNode) return;

  const itemsHtml = cachedActiveTasks.map((task) => {
    const taskId = encodeURIComponent(task.id || '');
    const href = '/tasks/' + taskId;
    const provider = sanitizeClassToken(task.provider || 'claude', 'claude');
    const providerLabel = escapeHtml(task.providerLabel || task.provider || 'Claude');
    const title = escapeHtml(task.title || 'Untitled Task');
    const statusClass = task.status === 'review'
      ? 'status-dot status-dot--warning'
      : 'status-dot status-dot--live';
    const trailingMeta = task.status === 'review'
      ? '<span class="running-review-label">review</span>'
      : task.startedAt
        ? '<span class="task-elapsed running-elapsed" data-started-at="' +
            escapeHtml(task.startedAt) +
            '"></span>'
        : '<span class="task-elapsed running-elapsed">--:--</span>';

    return (
      '<div class="session-item sidebar-running-item">' +
        '<a href="' + href + '" hx-get="' + href + '" class="session-item-link"' +
          ' hx-target="#main-content" hx-select="#main-content" hx-swap="outerHTML" hx-push-url="true"' +
          ' hx-select-oob="#topbar,#sidebar">' +
          '<span class="' + statusClass + '" aria-hidden="true"></span>' +
          '<span class="session-item-title">' + title + '</span>' +
          trailingMeta +
          '<span class="provider-badge provider-badge-' + provider + '">' + providerLabel + '</span>' +
        '</a>' +
      '</div>'
    );
  }).join('');

  const container = document.createElement('div');
  container.id = 'sidebar-running';
  container.innerHTML =
    '<div class="sidebar-section-label sidebar-running-label">Running</div>' +
    itemsHtml +
    '<hr class="sidebar-divider sidebar-running-divider">';

  if (existing) {
    existing.replaceWith(container);
  } else {
    chatsLabel.parentNode.insertBefore(container, chatsLabel);
  }

  htmx.process(container);
  initTaskElapsedTimers();
}

async function refreshSidebarTaskState() {
  if (!document.querySelector('[data-tasks-enabled]')) return;

  try {
    const response = await fetch('/api/tasks/sidebar-state');
    if (!response.ok) return;

    const payload = await response.json();
    latestTaskReviewCount = payload.reviewCount ?? 0;
    updateTaskBadge(latestTaskReviewCount);
    renderRunningSidebar(payload.activeTasks || []);
    renderWorkflowSidebar(payload.activeWorkflows || []);
  } catch (_) {}
}

function initTaskSse() {
  // Only connect when the server rendered an explicit task-SSE capability
  // marker. This avoids reconnect loops on taskless deployments.
  if (taskEventSource || !document.querySelector('[data-tasks-enabled]')) return;
  try {
    taskEventSource = new EventSource('/api/tasks/events');
  } catch (_) {
    return;
  }

  taskEventSource.onmessage = function(e) {
    try {
      const data = JSON.parse(e.data);

      if (data.type === 'connected') {
        updateTaskBadge(data.reviewCount || 0);
        renderRunningSidebar(data.activeTasks || []);
        renderWorkflowSidebar(data.activeWorkflows || []);
        if (Array.isArray(data.projects)) {
          data.projects.forEach(p => updateProjectStatusBadge(p.id, p.status));
        }
        return;
      }

      // Status change event — update badge and optionally refresh task list.
      if (data.type === 'task_status_changed') {
        updateTaskBadge(data.reviewCount || 0);
        renderRunningSidebar(data.activeTasks || []);
        if (Array.isArray(data.activeWorkflows)) {
          renderWorkflowSidebar(data.activeWorkflows);
        }
        if (shouldRefreshTaskContent(data.taskId)) {
          refreshTasksPageContent();
        }
        return;
      }

      if (data.type === 'workflow_sidebar_update') {
        renderWorkflowSidebar(data.activeWorkflows || []);
        if (data.notification) {
          incrementWorkflowNotification();
        }
        return;
      }

      if (data.type === 'agent_state') {
        if (shouldRefreshTaskContent(data.currentTaskId)) {
          refreshTasksPageContent();
        }
        return;
      }

      if (data.type === 'project_status') {
        updateProjectStatusBadge(data.projectId, data.newStatus);
        updateProjectSelectorOption(data.projectId, data.newStatus);
        return;
      }

      if (data.type === 'task_progress') {
        updateTaskProgress(data);
        updateDashboardProgress(data);
        return;
      }

      if (data.type === 'task_event') {
        updateDashboardEvents(data);
        return;
      }
    } catch (_) {}
  };

  taskEventSource.onerror = function() {
    // EventSource auto-reconnects. No custom logic needed.
  };
}

function updateTaskProgress(data) {
  const taskId = data.taskId;

  // Update activity indicator text.
  const activityEl = document.getElementById('task-activity-text-' + taskId);
  if (activityEl && data.currentActivity) {
    activityEl.textContent = data.currentActivity;
  }

  // Update progress bar fill width.
  const fillEl = document.getElementById('task-progress-fill-' + taskId);
  if (fillEl) {
    if (data.tokenBudget != null && data.tokenBudget > 0) {
      // Determinate progress.
      fillEl.classList.remove('indeterminate');
      const pct = Math.min(Math.max(data.progress || 0, 0), 100);
      fillEl.style.width = pct + '%';
      fillEl.setAttribute('aria-valuenow', pct);
    } else {
      // Indeterminate — pulsing animation via CSS class.
      fillEl.classList.add('indeterminate');
    }
  }

  // Update progress label text.
  const labelEl = document.getElementById('task-progress-label-' + taskId);
  if (labelEl) {
    if (data.tokenBudget != null && data.tokenBudget > 0) {
      labelEl.textContent = formatTokenCount(data.tokensUsed) +
        ' / ' + formatTokenCount(data.tokenBudget) +
        ' tokens (' + (data.progress || 0) + '%)';
    } else {
      labelEl.textContent = formatTokenCount(data.tokensUsed) + ' tokens used';
    }
  }

  // Show the progress section if hidden.
  const section = document.getElementById('task-progress-section');
  if (section) section.style.display = '';

  // On completion: hide the pulsing dot but keep final token count visible.
  if (data.isComplete) {
    const activityIndicator = document.getElementById('task-activity-' + taskId);
    if (activityIndicator) activityIndicator.style.display = 'none';
  }
}

// S11: Update running task card progress bar and token text on /tasks page.
function updateDashboardProgress(data) {
  const taskId = data.taskId;
  const progressEl = document.getElementById('task-progress-' + taskId);
  if (!progressEl) return; // not on /tasks page or task not visible

  const fillEl = progressEl.querySelector('.task-progress-fill');
  if (fillEl) {
    if (data.tokenBudget != null && data.tokenBudget > 0) {
      progressEl.classList.remove('task-progress-indeterminate');
      const pct = Math.min(Math.max(data.progress || 0, 0), 100);
      fillEl.style.width = pct + '%';
    } else {
      progressEl.classList.add('task-progress-indeterminate');
    }
  }

  const tokensEl = document.getElementById('task-tokens-' + taskId);
  if (tokensEl) {
    const span = tokensEl.querySelector('span');
    if (span) {
      if (data.tokenBudget != null && data.tokenBudget > 0) {
        span.textContent = formatTokenCount(data.tokensUsed) +
          ' / ' + formatTokenCount(data.tokenBudget) +
          ' tokens (' + (data.progress || 0) + '%)';
      } else {
        span.textContent = formatTokenCount(data.tokensUsed) + ' tokens';
      }
    }
  }

  // On completion: hide progress bar on dashboard card.
  if (data.isComplete) {
    progressEl.style.display = 'none';
  }
}

// S11: Prepend new event to compact timeline on /tasks card; keep max 3.
function updateDashboardEvents(data) {
  const taskId = data.taskId;
  let eventsEl = document.getElementById('task-events-' + taskId);

  // If the events container doesn't exist yet (task had no events on load), create it.
  if (!eventsEl) {
    const card = document.querySelector('[id^="task-progress-' + taskId + '"]');
    const parent = card ? card.closest('.task-card-running') : null;
    if (!parent) return;
    eventsEl = document.createElement('div');
    eventsEl.className = 'task-events';
    eventsEl.id = 'task-events-' + taskId;
    parent.appendChild(eventsEl);
  }

  const eventDiv = document.createElement('div');
  eventDiv.className = 'task-event';
  eventDiv.innerHTML =
    '<span class="task-event-icon ' + escapeHtml(data.iconClass || '') + '">' +
    escapeHtml(data.iconChar || '\u25CF') + '</span>' +
    '<span>' + escapeHtml(data.text || '') + '</span>';

  eventsEl.insertBefore(eventDiv, eventsEl.firstChild);
  while (eventsEl.children.length > 3) {
    eventsEl.removeChild(eventsEl.lastChild);
  }
}

function formatTokenCount(n) {
  if (n == null) return '0';
  return n.toLocaleString();
}

function currentTaskDetailId() {
  const detailPage = document.querySelector('.task-detail-page');
  return detailPage ? detailPage.getAttribute('data-task-id') : null;
}

function shouldRefreshTaskContent(taskId) {
  return Boolean(document.getElementById('tasks-content')) || currentTaskDetailId() === taskId;
}

function updateTaskBadge(count) {
  latestTaskReviewCount = count;
  const badge = document.getElementById('tasks-badge');
  if (!badge) return;
  if (count > 0) {
    badge.textContent = count;
    badge.style.display = '';
  } else {
    badge.style.display = 'none';
  }
}

function initTaskElapsedTimers() {
  const timers = document.querySelectorAll('.task-elapsed[data-started-at]');
  if (!timers.length) {
    if (taskElapsedTimer) {
      clearInterval(taskElapsedTimer);
      taskElapsedTimer = null;
    }
    return;
  }

  refreshTaskElapsedTimes();
  if (taskElapsedTimer) return;
  taskElapsedTimer = setInterval(refreshTaskElapsedTimes, 1000);
}

function initTaskDetailRefresh() {
  const detailPage = document.querySelector('.task-detail-page');
  if (!detailPage) {
    if (taskDetailRefreshTimer) {
      clearInterval(taskDetailRefreshTimer);
      taskDetailRefreshTimer = null;
    }
    return;
  }

  const statusText = detailPage
    .querySelector('.task-meta-card .status-badge')
    ?.textContent
    ?.trim()
    .toLowerCase();
  const shouldPoll = statusText === 'queued' || statusText === 'running';
  if (!shouldPoll) {
    if (taskDetailRefreshTimer) {
      clearInterval(taskDetailRefreshTimer);
      taskDetailRefreshTimer = null;
    }
    return;
  }

  if (taskDetailRefreshTimer) return;

  taskDetailRefreshTimer = setInterval(async () => {
    if (!document.querySelector('.task-detail-page')) {
      clearInterval(taskDetailRefreshTimer);
      taskDetailRefreshTimer = null;
      return;
    }

    await refreshTasksPageContent();

    const nextStatus = document
      .querySelector('.task-detail-page .task-meta-card .status-badge')
      ?.textContent
      ?.trim()
      .toLowerCase();
    if (nextStatus !== 'queued' && nextStatus !== 'running') {
      clearInterval(taskDetailRefreshTimer);
      taskDetailRefreshTimer = null;
    }
  }, 2000);
}

function refreshTaskElapsedTimes() {
  document.querySelectorAll('.task-elapsed[data-started-at]').forEach(el => {
    const started = el.getAttribute('data-started-at');
    if (!started) return;
    const diff = Math.floor((Date.now() - new Date(started).getTime()) / 1000);
    if (diff < 0) {
      el.textContent = '--:--';
      return;
    }
    const m = Math.floor(diff / 60);
    const s = diff % 60;
    el.textContent = m + 'm ' + String(s).padStart(2, '0') + 's';
  });
}

function restoreTaskBadge() {
  if (latestTaskReviewCount !== null) {
    updateTaskBadge(latestTaskReviewCount);
  }
}

// === WORKFLOW SIDEBAR ===

function renderWorkflowSidebar(workflows) {
  cachedActiveWorkflows = Array.isArray(workflows) ? workflows : [];

  const existing = document.getElementById('sidebar-workflows');
  if (!cachedActiveWorkflows.length) {
    existing && existing.remove();
    return;
  }

  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;

  // Find insertion point: after #sidebar-running if present, else before "Chats" label.
  const runningSection = document.getElementById('sidebar-running');
  const chatsLabel = Array.from(sidebar.querySelectorAll('.sidebar-section-label'))
    .find((el) => el.textContent.trim() === 'Chats');
  if (!chatsLabel || !chatsLabel.parentNode) return;

  const itemsHtml = cachedActiveWorkflows.map((wf) => {
    const wfId = encodeURIComponent(wf.id || '');
    const href = '/workflows/' + wfId;
    const name = escapeHtml(wf.definitionName || 'Workflow');
    const progress = (wf.completedSteps || 0) + '/' + (wf.totalSteps || 0);
    const statusClass = wf.status === 'paused'
      ? 'status-dot status-dot--warning'
      : 'status-dot status-dot--live';

    return (
      '<div class="session-item sidebar-workflow-item">' +
        '<a href="' + href + '" hx-get="' + href + '" class="session-item-link"' +
          ' hx-target="#main-content" hx-select="#main-content" hx-swap="outerHTML"' +
          ' hx-push-url="true" hx-select-oob="#topbar,#sidebar">' +
          '<span class="' + statusClass + '" aria-hidden="true"></span>' +
          '<span class="session-item-title">' + name + '</span>' +
          '<span class="workflow-step-progress">' + progress + '</span>' +
        '</a>' +
      '</div>'
    );
  }).join('');

  const container = document.createElement('div');
  container.id = 'sidebar-workflows';
  container.innerHTML =
    '<div class="sidebar-section-label sidebar-workflows-label">Workflows</div>' +
    itemsHtml +
    '<hr class="sidebar-divider sidebar-workflows-divider">';

  if (existing) {
    existing.replaceWith(container);
  } else {
    // Insert after running section if present, otherwise before Chats.
    const insertBefore = runningSection
      ? runningSection.nextElementSibling
      : chatsLabel;
    if (insertBefore && insertBefore.parentNode) {
      insertBefore.parentNode.insertBefore(container, insertBefore);
    } else {
      chatsLabel.parentNode.insertBefore(container, chatsLabel);
    }
  }

  htmx.process(container);
}

function updateWorkflowBadge(count) {
  workflowNotificationCount = count;
  const badge = document.getElementById('workflows-badge');
  if (!badge) return;
  if (count > 0) {
    badge.textContent = count;
    badge.style.display = '';
  } else {
    badge.style.display = 'none';
  }
}

function incrementWorkflowNotification() {
  // Only increment if NOT currently on the workflows page.
  if (window.location.pathname === '/workflows') return;
  workflowNotificationCount++;
  updateWorkflowBadge(workflowNotificationCount);
}

function resetWorkflowNotification() {
  workflowNotificationCount = 0;
  updateWorkflowBadge(0);
}

function resetWorkflowNotificationIfOnWorkflowsPage() {
  if (window.location.pathname === '/workflows') {
    resetWorkflowNotification();
  }
}

function filterByDefinition(value) {
  const url = new URL(window.location.href);
  if (value) {
    url.searchParams.set('definition', value);
  } else {
    url.searchParams.delete('definition');
  }
  htmx.ajax('GET', url.pathname + url.search, {
    target: '#main-content',
    select: '#main-content',
    swap: 'outerHTML',
    headers: { 'HX-Push-Url': url.pathname + url.search },
  });
}

async function refreshTasksPageContent() {
  try {
    const response = await fetch(window.location.pathname + window.location.search, {
      headers: { 'HX-Request': 'true' },
    });
    if (!response.ok) return;

    const html = await response.text();
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    const nextContent = parsed.getElementById('tasks-content');
    const currentContent = document.getElementById('tasks-content');
    if (!nextContent || !currentContent) return;

    currentContent.replaceWith(nextContent);
    initTaskElapsedTimers();
    initTaskListControls();
    initTaskReviewActions();
    initTaskStartActions();
    initTaskCancelActions();
    initTaskDialogTabs();
    initNewTaskForm();
    initTaskDetailRefresh();
    renderMarkdown();
  } catch (_) {}
}

async function refreshTaskDetailContent() {
  try {
    const response = await fetch(window.location.pathname + window.location.search, {
      headers: { 'HX-Request': 'true' },
    });
    if (!response.ok) return;

    const html = await response.text();
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    const nextContent = parsed.getElementById('main-content');
    const currentContent = document.getElementById('main-content');
    if (!nextContent || !currentContent) return;

    currentContent.replaceWith(nextContent);
    initTaskElapsedTimers();
    initTaskListControls();
    initTaskReviewActions();
    initTaskStartActions();
    initTaskCancelActions();
    initTaskDialogTabs();
    initNewTaskForm();
    initTaskDetailRefresh();
    renderMarkdown();
  } catch (_) {}
}

window.applyTaskFilters = function() {
  const status = document.getElementById('task-status-filter');
  const type = document.getElementById('task-type-filter');
  const params = new URLSearchParams();
  if (status && status.value) params.set('status', status.value);
  if (type && type.value) params.set('type', type.value);
  const qs = params.toString();
  window.location.href = '/tasks' + (qs ? '?' + qs : '');
};

function initTaskListControls() {
  document.querySelectorAll('[data-task-filter]').forEach(select => {
    if (select.dataset.taskFilterInit) return;
    select.dataset.taskFilterInit = '1';
    select.addEventListener('change', window.applyTaskFilters);
  });

  document.querySelectorAll('[data-task-dialog-open]').forEach(button => {
    if (button.dataset.taskDialogOpenInit) return;
    button.dataset.taskDialogOpenInit = '1';
    button.addEventListener('click', function() {
      const dialog = document.getElementById('new-task-dialog');
      if (dialog) dialog.showModal();
    });
  });

  document.querySelectorAll('[data-task-dialog-close]').forEach(button => {
    if (button.dataset.taskDialogCloseInit) return;
    button.dataset.taskDialogCloseInit = '1';
    button.addEventListener('click', function() {
      const dialog = button.closest('dialog');
      if (dialog) dialog.close();
    });
  });
}

// === TASK DETAIL: REVIEW ACTIONS ===

function initTaskReviewActions() {
  const reviewBar = document.querySelector('.task-review-bar');
  if (!reviewBar || reviewBar.dataset.reviewInit) return;
  reviewBar.dataset.reviewInit = '1';

  const page = document.querySelector('.task-detail-page');
  const taskId = page ? page.getAttribute('data-task-id') : null;
  if (!taskId) return;

  const token = new URLSearchParams(window.location.search).get('token');
  const qs = token ? '?token=' + encodeURIComponent(token) : '';

  reviewBar.addEventListener('click', async function(e) {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const action = btn.getAttribute('data-action');

    if (action === 'push_back') {
      const commentArea = reviewBar.querySelector('.pushback-comment');
      if (commentArea && commentArea.style.display === 'none') {
        commentArea.style.display = '';
        return;
      }
    }

    if (action === 'push_back') {
      // handled by submit button
      return;
    }

    try {
      const resp = await fetch('/api/tasks/' + taskId + '/review' + qs, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: action }),
      });
      if (resp.ok) {
        window.location.href = '/tasks' + qs;
      } else {
        const data = await resp.json().catch(() => ({}));
        showToast('error', data.error?.message || 'Review action failed');
      }
    } catch (_) {
      showToast('error', 'Failed to reach server');
    }
  });

  // Push-back submit
  const submitBtn = reviewBar.querySelector('.btn-pushback-submit');
  if (submitBtn) {
    submitBtn.addEventListener('click', async function() {
      const textarea = document.getElementById('pushback-comment');
      const comment = textarea ? textarea.value.trim() : '';
      if (!comment) {
        showToast('error', 'Comment is required for push back');
        return;
      }
      try {
        const resp = await fetch('/api/tasks/' + taskId + '/review' + qs, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'push_back', comment: comment }),
        });
        if (resp.ok) {
          window.location.href = '/tasks' + qs;
        } else {
          const data = await resp.json().catch(() => ({}));
          showToast('error', data.error?.message || 'Push back failed');
        }
      } catch (_) {
        showToast('error', 'Failed to reach server');
      }
    });
  }
}

function initTaskStartActions() {
  const page = document.querySelector('.task-detail-page');
  if (!page) return;

  const startBtn = page.querySelector('[data-task-start]');
  if (!startBtn || startBtn.dataset.taskStartInit) return;
  startBtn.dataset.taskStartInit = '1';

  const taskId = page.getAttribute('data-task-id');
  if (!taskId) return;

  const token = new URLSearchParams(window.location.search).get('token');
  const qs = token ? '?token=' + encodeURIComponent(token) : '';

  startBtn.addEventListener('click', async function() {
    startBtn.disabled = true;
    try {
      const resp = await fetch('/api/tasks/' + taskId + '/start' + qs, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
      });
      if (resp.ok) {
        window.location.reload();
      } else {
        const data = await resp.json().catch(() => ({}));
        showToast('error', data.error?.message || 'Failed to start task');
        startBtn.disabled = false;
      }
    } catch (_) {
      showToast('error', 'Failed to reach server');
      startBtn.disabled = false;
    }
  });
}

function initTaskCancelActions() {
  const page = document.querySelector('.task-detail-page');
  if (!page) return;

  const cancelBtn = page.querySelector('[data-task-cancel]');
  if (!cancelBtn || cancelBtn.dataset.taskCancelInit) return;
  cancelBtn.dataset.taskCancelInit = '1';

  const taskId = page.getAttribute('data-task-id');
  if (!taskId) return;

  const token = new URLSearchParams(window.location.search).get('token');
  const qs = token ? '?token=' + encodeURIComponent(token) : '';

  cancelBtn.addEventListener('click', async function() {
    cancelBtn.disabled = true;
    try {
      const resp = await fetch('/api/tasks/' + taskId + '/cancel' + qs, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
      });
      if (resp.ok) {
        window.location.href = '/tasks' + qs;
      } else {
        const data = await resp.json().catch(() => ({}));
        showToast('error', data.error?.message || 'Failed to cancel task');
        cancelBtn.disabled = false;
      }
    } catch (_) {
      showToast('error', 'Failed to reach server');
      cancelBtn.disabled = false;
    }
  });
}

// === NEW TASK FORM ===

// === WORKFLOW PICKER ===

let cachedWorkflowDefs = null;
let selectedWorkflow = null;

function initTaskDialogTabs() {
  const tabBtns = document.querySelectorAll('[data-task-tab]');
  const tabPanels = document.querySelectorAll('[data-task-panel]');
  const submitBtn = document.getElementById('task-dialog-submit');
  const dialog = document.getElementById('new-task-dialog');

  let workflowsFetched = false;

  tabBtns.forEach(btn => {
    if (btn.dataset.taskTabInit) return;
    btn.dataset.taskTabInit = '1';
    btn.addEventListener('click', () => {
      const target = btn.dataset.taskTab;
      tabBtns.forEach(b => b.classList.toggle('active', b.dataset.taskTab === target));
      tabPanels.forEach(p => p.classList.toggle('active', p.dataset.taskPanel === target));
      if (submitBtn) {
        submitBtn.textContent = target === 'workflow' ? 'Run Workflow' : 'Create Task';
      }
      if (target === 'workflow' && !workflowsFetched) {
        workflowsFetched = true;
        fetchWorkflowDefinitions();
      }
      const errorEl = document.getElementById('new-task-error');
      if (errorEl) errorEl.textContent = '';
    });
  });

  // Reset state when dialog closes.
  if (dialog && !dialog.dataset.workflowCloseInit) {
    dialog.dataset.workflowCloseInit = '1';
    dialog.addEventListener('close', function() {
      selectedWorkflow = null;
      cachedWorkflowDefs = null;
      workflowsFetched = false;

      // Reset to Single Task tab.
      tabBtns.forEach(b => b.classList.toggle('active', b.dataset.taskTab === 'single'));
      tabPanels.forEach(p => p.classList.toggle('active', p.dataset.taskPanel === 'single'));

      if (submitBtn) submitBtn.textContent = 'Create Task';

      const listCards = document.querySelector('.workflow-list-cards');
      if (listCards) listCards.innerHTML = '';
      const formEl = document.getElementById('workflow-form');
      if (formEl) formEl.style.display = 'none';
      const loadingEl = document.querySelector('.workflow-list-loading');
      if (loadingEl) loadingEl.style.display = 'none';
      const emptyEl = document.querySelector('.workflow-list-empty');
      if (emptyEl) emptyEl.style.display = 'none';
      const errorEl = document.getElementById('new-task-error');
      if (errorEl) errorEl.textContent = '';

      const formEl2 = document.getElementById('new-task-form');
      if (formEl2) formEl2.reset();
    });
  }
}

function fetchWorkflowDefinitions() {
  const listCards = document.querySelector('.workflow-list-cards');
  const loadingEl = document.querySelector('.workflow-list-loading');
  const emptyEl = document.querySelector('.workflow-list-empty');
  if (!listCards) return;

  const token = new URLSearchParams(window.location.search).get('token');
  const qs = token ? '?token=' + encodeURIComponent(token) : '';

  if (loadingEl) loadingEl.style.display = '';
  if (emptyEl) emptyEl.style.display = 'none';
  listCards.innerHTML = '';

  fetch('/api/workflows/definitions' + qs)
    .then(resp => {
      if (!resp.ok) throw new Error('Failed to load workflows');
      return resp.json();
    })
    .then(definitions => {
      cachedWorkflowDefs = definitions;
      if (loadingEl) loadingEl.style.display = 'none';
      if (!definitions.length) {
        if (emptyEl) emptyEl.style.display = '';
        return;
      }
      listCards.innerHTML = definitions.map(renderWorkflowCard).join('');
      listCards.querySelectorAll('.workflow-card').forEach(card => {
        card.addEventListener('click', () => selectWorkflow(card.dataset.workflowName));
      });
    })
    .catch(err => {
      if (loadingEl) loadingEl.style.display = 'none';
      listCards.innerHTML =
        '<p class="empty-state-text">Failed to load workflows. ' +
        escapeHtml(err.message) + '</p>';
    });
}

function renderWorkflowCard(def) {
  const name = escapeHtml(def.name);
  const desc = escapeHtml(def.description || '');
  const steps = def.stepCount || 0;
  const loopBadge = def.hasLoops
    ? '<span class="workflow-badge workflow-badge-loop">Loop</span>'
    : '';
  const varCount = Object.keys(def.variables || {}).length;
  return (
    '<div class="card workflow-card" data-workflow-name="' + name + '">' +
      '<div class="workflow-card-header">' +
        '<span class="workflow-card-name">' + formatWorkflowName(def.name) + '</span>' +
        '<span class="workflow-card-steps">' + steps + ' step' + (steps !== 1 ? 's' : '') + '</span>' +
      '</div>' +
      '<div class="workflow-card-desc">' + desc + '</div>' +
      '<div class="workflow-card-meta">' +
        '<span class="workflow-badge">' + varCount + ' variable' + (varCount !== 1 ? 's' : '') + '</span>' +
        loopBadge +
      '</div>' +
    '</div>'
  );
}

function formatWorkflowName(name) {
  // "spec-and-implement" -> "Spec and Implement"
  return escapeHtml(
    name.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
  );
}

function selectWorkflow(name) {
  const formEl = document.getElementById('workflow-form');
  const varsEl = document.getElementById('workflow-vars');
  const projectEl = document.getElementById('workflow-project-select');

  // Toggle: clicking the same workflow deselects it.
  if (selectedWorkflow === name) {
    selectedWorkflow = null;
    if (formEl) formEl.style.display = 'none';
    document.querySelectorAll('.workflow-card').forEach(c => c.classList.remove('workflow-card-selected'));
    return;
  }

  selectedWorkflow = name;
  const def = (cachedWorkflowDefs || []).find(d => d.name === name);
  if (!def) return;

  document.querySelectorAll('.workflow-card').forEach(
    c => c.classList.toggle('workflow-card-selected', c.dataset.workflowName === name)
  );

  const vars = def.variables || {};
  const varNames = Object.keys(vars);

  if (varsEl) {
    if (varNames.length === 0) {
      varsEl.innerHTML = '<p class="empty-state-text">This workflow has no input variables.</p>';
    } else {
      varsEl.innerHTML = varNames.map(varName => {
        const v = vars[varName] || {};
        const isRequired = v.required !== false;
        const label = formatVariableName(varName);
        const placeholder = escapeHtml(v.description || '');
        const defaultVal = v.default != null ? escapeHtml(String(v.default)) : '';
        const requiredAttr = isRequired ? ' required' : '';
        const requiredMark = isRequired ? ' <span class="form-required">*</span>' : '';
        const isLongForm = ['FEATURE', 'BUG_DESCRIPTION', 'QUESTION', 'TARGET'].includes(varName);
        const inputHtml = isLongForm
          ? '<textarea class="form-input" name="wf-var-' + escapeHtml(varName) +
            '" rows="3" placeholder="' + placeholder + '"' + requiredAttr + '>' +
            defaultVal + '</textarea>'
          : '<input type="text" class="form-input" name="wf-var-' + escapeHtml(varName) +
            '" value="' + defaultVal + '" placeholder="' + placeholder + '"' +
            requiredAttr + '>';
        return (
          '<div class="form-group">' +
            '<label class="form-label">' + label + requiredMark + '</label>' +
            inputHtml +
          '</div>'
        );
      }).join('');
    }
  }

  // Show/hide project selector based on PROJECT variable.
  const hasProjectVar = varNames.some(k => k.toUpperCase() === 'PROJECT');
  if (projectEl) projectEl.style.display = hasProjectVar ? '' : 'none';
  if (formEl) formEl.style.display = '';
}

function formatVariableName(name) {
  // "FEATURE" -> "Feature", "BUG_DESCRIPTION" -> "Bug Description"
  return escapeHtml(
    name.toLowerCase().replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
  );
}

async function handleWorkflowSubmit(errorEl) {
  if (!selectedWorkflow) {
    if (errorEl) errorEl.textContent = 'Please select a workflow.';
    return;
  }
  const def = (cachedWorkflowDefs || []).find(d => d.name === selectedWorkflow);
  if (!def) {
    if (errorEl) errorEl.textContent = 'Selected workflow not found.';
    return;
  }

  const variables = {};
  const varNames = Object.keys(def.variables || {});
  for (const varName of varNames) {
    const input = document.querySelector('[name="wf-var-' + varName + '"]');
    if (!input) continue;
    const value = input.value.trim();
    if ((def.variables[varName] || {}).required !== false && !value) {
      if (errorEl) errorEl.textContent = formatVariableName(varName) + ' is required.';
      input.focus();
      return;
    }
    if (value) variables[varName] = value;
  }

  const projectSelect = document.getElementById('workflow-project');
  const project = projectSelect ? projectSelect.value : '';
  if (project && def.variables && def.variables['PROJECT'] !== undefined) {
    variables['PROJECT'] = project;
  }

  const token = new URLSearchParams(window.location.search).get('token');
  const qs = token ? '?token=' + encodeURIComponent(token) : '';

  const body = { definition: selectedWorkflow, variables };
  if (project) body.project = project;

  try {
    const resp = await fetch('/api/workflows/run' + qs, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (resp.ok || resp.status === 201) {
      const data = await resp.json();
      const dialog = document.getElementById('new-task-dialog');
      if (dialog) dialog.close();
      if (data.id) {
        window.location.href = '/workflows/' + data.id + qs;
      } else {
        window.location.href = '/tasks' + qs;
      }
    } else {
      const data = await resp.json().catch(() => ({}));
      if (errorEl) errorEl.textContent = (data.error && data.error.message) || 'Failed to start workflow';
    }
  } catch (_) {
    if (errorEl) errorEl.textContent = 'Failed to reach server';
  }
}

function initNewTaskForm() {
  const form = document.getElementById('new-task-form');
  if (!form || form.dataset.taskFormInit) return;
  form.dataset.taskFormInit = '1';

  const token = new URLSearchParams(window.location.search).get('token');
  const qs = token ? '?token=' + encodeURIComponent(token) : '';
  const typeSelect = form.querySelector('[name="type"]');
  const goalSelect = form.querySelector('[name="goalId"]');
  const hintEl = form.querySelector('[data-task-type-hint]');
  const descriptionLabel = form.querySelector('[data-task-description-label]');
  const descriptionInput = form.querySelector('[data-task-description-input]');
  const criteriaLabel = form.querySelector('[data-task-criteria-label]');
  const criteriaInput = form.querySelector('[data-task-criteria-input]');

  const typeConfig = {
    coding: {
      hint: 'Coding tasks run in isolated git worktrees and produce diffs for review.',
      descriptionLabel: 'Implementation Brief',
      descriptionPlaceholder: 'What should change in the codebase?',
      criteriaLabel: 'Definition of Done',
      criteriaPlaceholder: 'What files, behaviors, or tests should be complete?',
    },
    research: {
      hint: 'Research tasks produce reviewable written artifacts and can run in the restricted profile.',
      descriptionLabel: 'Research Brief',
      descriptionPlaceholder: 'What should the agent investigate or summarize?',
      criteriaLabel: 'Success Criteria',
      criteriaPlaceholder: 'What should the final write-up answer or include?',
    },
    writing: {
      hint: 'Writing tasks focus on producing polished documents or copy for review.',
      descriptionLabel: 'Writing Brief',
      descriptionPlaceholder: 'What should the agent write or rewrite?',
      criteriaLabel: 'Editorial Criteria',
      criteriaPlaceholder: 'Tone, audience, structure, and completion criteria',
    },
    analysis: {
      hint: 'Analysis tasks are best for diagnostics, comparisons, and structured conclusions.',
      descriptionLabel: 'Analysis Brief',
      descriptionPlaceholder: 'What should the agent analyze?',
      criteriaLabel: 'Expected Output',
      criteriaPlaceholder: 'What conclusion, report, or artifact should come back?',
    },
    automation: {
      hint: 'Automation tasks are useful for repeatable operational runs that still end in review.',
      descriptionLabel: 'Automation Brief',
      descriptionPlaceholder: 'What repeatable operation should the agent run?',
      criteriaLabel: 'Completion Check',
      criteriaPlaceholder: 'What makes the run successful and ready for review?',
    },
    custom: {
      hint: 'Custom tasks use the generic task pipeline when none of the standard types fit cleanly.',
      descriptionLabel: 'Task Brief',
      descriptionPlaceholder: 'Describe the task clearly and concretely.',
      criteriaLabel: 'Acceptance Criteria',
      criteriaPlaceholder: 'How will you know when it is done?',
    },
  };

  function applyTaskTypeFormBehavior() {
    const config = typeConfig[(typeSelect && typeSelect.value) || 'custom'] || typeConfig.custom;
    if (hintEl) hintEl.textContent = config.hint;
    if (descriptionLabel) descriptionLabel.textContent = config.descriptionLabel;
    if (descriptionInput) descriptionInput.placeholder = config.descriptionPlaceholder;
    if (criteriaLabel) criteriaLabel.textContent = config.criteriaLabel;
    if (criteriaInput) criteriaInput.placeholder = config.criteriaPlaceholder;
  }

  if (typeSelect && !typeSelect.dataset.taskTypeInit) {
    typeSelect.dataset.taskTypeInit = '1';
    typeSelect.addEventListener('change', applyTaskTypeFormBehavior);
  }
  applyTaskTypeFormBehavior();

  form.addEventListener('submit', async function(e) {
    e.preventDefault();
    const errorEl = document.getElementById('new-task-error');

    const activePanel = document.querySelector('[data-task-panel].active');
    const isWorkflow = activePanel && activePanel.dataset.taskPanel === 'workflow';
    if (isWorkflow) {
      await handleWorkflowSubmit(errorEl);
      return;
    }

    const title = form.querySelector('[name="title"]').value.trim();
    const description = form.querySelector('[name="description"]').value.trim();
    const type = form.querySelector('[name="type"]').value;
    const goalId = goalSelect ? goalSelect.value.trim() : '';
    const acceptanceCriteria = form.querySelector('[name="acceptanceCriteria"]').value.trim();
    const model = form.querySelector('[name="model"]').value.trim();
    const tokenBudget = form.querySelector('[name="tokenBudget"]').value.trim();
    const allowedToolsChecked = Array.from(form.querySelectorAll('[name="allowedTools"]:checked')).map(cb => cb.value);
    const reviewMode = (form.querySelector('[name="reviewMode"]') || {}).value || '';
    const autoStart = form.querySelector('[name="autoStart"]').checked;

    if (!title || !description || !type) {
      if (errorEl) errorEl.textContent = 'Title, description, and type are required.';
      return;
    }

    const projectSelect = form.querySelector('[name="projectId"]');
    const projectId = projectSelect ? projectSelect.value.trim() : '';

    const body = { title, description, type, autoStart };
    if (goalId) body.goalId = goalId;
    if (projectId) body.projectId = projectId;
    if (acceptanceCriteria) body.acceptanceCriteria = acceptanceCriteria;
    if (model) body.configJson = { model };
    if (tokenBudget) body.configJson = { ...(body.configJson || {}), tokenBudget: parseInt(tokenBudget, 10) };
    if (allowedToolsChecked.length > 0) body.configJson = { ...(body.configJson || {}), allowedTools: allowedToolsChecked };
    if (reviewMode) body.configJson = { ...(body.configJson || {}), reviewMode };

    try {
      const resp = await fetch('/api/tasks' + qs, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (resp.ok || resp.status === 201) {
        const data = await resp.json();
        const dialog = document.getElementById('new-task-dialog');
        if (dialog) dialog.close();
        window.location.href = '/tasks/' + data.id + qs;
      } else {
        const data = await resp.json().catch(() => ({}));
        if (errorEl) errorEl.textContent = data.error?.message || 'Failed to create task';
      }
    } catch (_) {
      if (errorEl) errorEl.textContent = 'Failed to reach server';
    }
  });
}

// === PROJECT MANAGEMENT ===

function updateProjectStatusBadge(projectId, newStatus) {
  const card = document.querySelector('[data-project-id="' + projectId + '"]');
  if (!card) return;

  const badge = card.querySelector('.status-badge');
  if (badge) {
    const classMap = {
      ready: 'status-badge-success',
      cloning: 'status-badge-info',
      error: 'status-badge-error',
      stale: 'status-badge-warning',
    };
    badge.className = 'status-badge ' + (classMap[newStatus] || '');
    badge.textContent = newStatus.charAt(0).toUpperCase() + newStatus.slice(1);
  }

  const errorBanner = card.querySelector('.project-error-banner');
  if (newStatus === 'ready' && errorBanner) {
    errorBanner.style.display = 'none';
  } else if (newStatus !== 'ready' && newStatus !== 'cloning' && errorBanner) {
    errorBanner.style.display = '';
  }
}

function updateProjectSelectorOption(projectId, newStatus) {
  const select = document.getElementById('task-project-select');
  if (!select) return;
  const option = select.querySelector('option[value="' + projectId + '"]');
  if (!option) return;

  const isReady = newStatus === 'ready';
  option.disabled = !isReady;

  const baseName = option.textContent.replace(/ [\u2713\u26a0]$/, '').replace(/ \(cloning\)$/, '').replace(/ \(error\)$/, '').trim();
  const indicator = newStatus === 'ready' ? ' \u2713' : newStatus === 'cloning' ? ' (cloning)' : newStatus === 'error' ? ' (error)' : newStatus === 'stale' ? ' \u26a0' : '';
  option.textContent = baseName + indicator;
}

function initProjectHandlers() {
  // Open "Add Project" dialog.
  document.addEventListener('click', function(e) {
    if (e.target.closest('[data-project-dialog-open]')) {
      const dialog = document.getElementById('add-project-dialog');
      if (dialog) {
        dialog.querySelector('form')?.reset();
        const errorEl = dialog.querySelector('#add-project-error');
        if (errorEl) errorEl.textContent = '';
        dialog.showModal();
      }
    }
  });

  // Close project dialog.
  document.addEventListener('click', function(e) {
    if (e.target.closest('[data-project-dialog-close]')) {
      const dialog = document.getElementById('add-project-dialog');
      if (dialog) dialog.close();
    }
  });

  // "Add Project" form submit.
  document.addEventListener('submit', async function(e) {
    if (e.target.id !== 'add-project-form') return;
    e.preventDefault();
    const form = e.target;
    const errorEl = document.getElementById('add-project-error');

    const remoteUrl = form.querySelector('[name="remoteUrl"]')?.value.trim() || '';
    const name = form.querySelector('[name="name"]')?.value.trim() || '';
    const defaultBranch = form.querySelector('[name="defaultBranch"]')?.value.trim() || 'main';
    const credentialsRef = form.querySelector('[name="credentialsRef"]')?.value.trim() || '';
    const prStrategy = form.querySelector('[name="prStrategy"]')?.value || 'branchOnly';
    const draft = form.querySelector('[name="draft"]')?.checked ?? true;
    const labelsRaw = form.querySelector('[name="labels"]')?.value.trim() || '';
    const labels = labelsRaw ? labelsRaw.split(',').map(l => l.trim()).filter(Boolean) : [];

    if (!remoteUrl || !name) {
      if (errorEl) errorEl.textContent = 'Remote URL and Name are required.';
      return;
    }

    const body = { remoteUrl, name, defaultBranch, pr: { strategy: prStrategy, draft, labels } };
    if (credentialsRef) body.credentialsRef = credentialsRef;

    try {
      const resp = await fetch('/api/projects', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (resp.ok || resp.status === 201) {
        const dialog = document.getElementById('add-project-dialog');
        if (dialog) dialog.close();
        window.location.reload();
      } else {
        const data = await resp.json().catch(() => ({}));
        if (errorEl) errorEl.textContent = data.error?.message || 'Failed to add project';
      }
    } catch (_) {
      if (errorEl) errorEl.textContent = 'Failed to reach server';
    }
  });

  // "Fetch" button handler.
  document.addEventListener('click', async function(e) {
    const btn = e.target.closest('[data-project-fetch]');
    if (!btn) return;
    const projectId = btn.dataset.projectFetch;
    btn.disabled = true;
    const origText = btn.textContent;
    btn.textContent = 'Fetching…';
    try {
      const resp = await fetch('/api/projects/' + projectId + '/fetch', { method: 'POST' });
      if (resp.ok) {
        window.location.reload();
      } else {
        const data = await resp.json().catch(() => ({}));
        showToast('error', data.error?.message || 'Fetch failed');
      }
    } catch (_) {
      showToast('error', 'Failed to reach server');
    } finally {
      btn.disabled = false;
      btn.textContent = origText;
    }
  });

  // "Remove" button handler.
  document.addEventListener('click', async function(e) {
    const btn = e.target.closest('[data-project-remove]');
    if (!btn) return;
    const projectId = btn.dataset.projectRemove;
    const projectName = btn.dataset.projectName || projectId;
    const confirmed = window.confirm(
      'Remove project \'' + projectName + '\'? Running tasks will be cancelled.'
    );
    if (!confirmed) return;
    try {
      const resp = await fetch('/api/projects/' + projectId, { method: 'DELETE' });
      if (resp.ok || resp.status === 204) {
        window.location.reload();
      } else {
        const data = await resp.json().catch(() => ({}));
        showToast('error', data.error?.message || 'Failed to remove project');
      }
    } catch (_) {
      showToast('error', 'Failed to reach server');
    }
  });

  // "Edit" button handler — pre-fill and re-use the add dialog.
  document.addEventListener('click', function(e) {
    const btn = e.target.closest('[data-project-edit]');
    if (!btn) return;
    const projectId = btn.dataset.projectEdit;
    const dialog = document.getElementById('add-project-dialog');
    if (!dialog) return;

    dialog.querySelector('h2').textContent = 'Edit Project';
    dialog.querySelector('[type="submit"]').textContent = 'Save Changes';
    const form = dialog.querySelector('form');
    form.dataset.editProjectId = projectId;
    const errorEl = dialog.querySelector('#add-project-error');
    if (errorEl) errorEl.textContent = '';

    const setVal = (name, value) => {
      const el = form.querySelector('[name="' + name + '"]');
      if (el) el.value = value || '';
    };
    const setChecked = (name, value) => {
      const el = form.querySelector('[name="' + name + '"]');
      if (el) el.checked = value === 'true' || value === true;
    };
    setVal('remoteUrl', btn.dataset.projectUrl);
    setVal('name', btn.dataset.projectName);
    setVal('defaultBranch', btn.dataset.projectBranch);
    setVal('credentialsRef', btn.dataset.projectCreds);
    setVal('prStrategy', btn.dataset.projectStrategy);
    setChecked('draft', btn.dataset.projectDraft);
    setVal('labels', btn.dataset.projectLabels);

    dialog.showModal();
  });

  // Override add-project form submit for edit mode.
  document.addEventListener('submit', async function(e) {
    if (e.target.id !== 'add-project-form') return;
    const form = e.target;
    const editProjectId = form.dataset.editProjectId;
    if (!editProjectId) return; // handled by the add handler above
    e.stopImmediatePropagation();
    e.preventDefault();

    const errorEl = document.getElementById('add-project-error');
    const remoteUrl = form.querySelector('[name="remoteUrl"]')?.value.trim() || '';
    const name = form.querySelector('[name="name"]')?.value.trim() || '';
    const defaultBranch = form.querySelector('[name="defaultBranch"]')?.value.trim() || 'main';
    const credentialsRef = form.querySelector('[name="credentialsRef"]')?.value.trim() || '';
    const prStrategy = form.querySelector('[name="prStrategy"]')?.value || 'branchOnly';
    const draft = form.querySelector('[name="draft"]')?.checked ?? true;
    const labelsRaw = form.querySelector('[name="labels"]')?.value.trim() || '';
    const labels = labelsRaw ? labelsRaw.split(',').map(l => l.trim()).filter(Boolean) : [];

    const body = { name, defaultBranch, pr: { strategy: prStrategy, draft, labels } };
    if (remoteUrl) body.remoteUrl = remoteUrl;
    if (credentialsRef) body.credentialsRef = credentialsRef;

    try {
      const resp = await fetch('/api/projects/' + editProjectId, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (resp.ok) {
        delete form.dataset.editProjectId;
        const dialog = document.getElementById('add-project-dialog');
        if (dialog) {
          dialog.querySelector('h2').textContent = 'Add Project';
          dialog.querySelector('[type="submit"]').textContent = 'Add Project';
          dialog.close();
        }
        window.location.reload();
      } else if (resp.status === 409) {
        const data = await resp.json().catch(() => ({}));
        if (errorEl) errorEl.textContent = data.error?.message || 'Cannot edit: active tasks exist on this project';
      } else {
        const data = await resp.json().catch(() => ({}));
        if (errorEl) errorEl.textContent = data.error?.message || 'Failed to update project';
      }
    } catch (_) {
      if (errorEl) errorEl.textContent = 'Failed to reach server';
    }
  }, true); // capture=true so this runs before the add handler
}

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

// === WORKFLOW DETAIL SSE ===

let workflowEventSource = null;

function initWorkflowDetailSSE() {
  const detailPage = document.querySelector('.workflow-detail-page');
  if (!detailPage) {
    cleanupWorkflowSSE();
    return;
  }

  const runId = detailPage.getAttribute('data-run-id');
  if (!runId || workflowEventSource) return;

  workflowEventSource = new EventSource(
    '/api/workflows/runs/' + runId + '/events',
    { withCredentials: true }
  );

  workflowEventSource.onmessage = function(event) {
    try {
      const data = JSON.parse(event.data);
      handleWorkflowEvent(data);
    } catch (_) {}
  };

  workflowEventSource.onerror = function() {
    // Reconnect handled automatically by EventSource.
  };
}

function cleanupWorkflowSSE() {
  if (workflowEventSource) {
    workflowEventSource.close();
    workflowEventSource = null;
  }
}

function handleWorkflowEvent(data) {
  switch (data.type) {
    case 'connected':
      // Initial state already rendered server-side.
      break;
    case 'workflow_status_changed':
      updateWorkflowStatus(data);
      break;
    case 'workflow_step_completed':
      updateStepCompleted(data);
      updateProgressBar(data);
      break;
    case 'task_status_changed':
      updateStepTaskStatus(data);
      break;
    case 'loop_iteration_completed':
      updateLoopIteration(data);
      break;
    case 'parallel_group_completed':
      updateParallelGroup(data);
      break;
  }
}

function updateWorkflowStatus(data) {
  const badge = document.querySelector('.workflow-meta-card .status-badge');
  if (badge) {
    badge.textContent = _wfTitleCase(data.newStatus);
    badge.className = 'status-badge status-badge-' + data.newStatus;
  }

  const errorEl = document.querySelector('.workflow-error-message');
  if (data.errorMessage && errorEl) {
    const msgSpan = errorEl.querySelector('span:last-child');
    if (msgSpan) msgSpan.textContent = data.errorMessage;
    errorEl.style.display = '';
  }

  const isRunning = data.newStatus === 'running';
  const isPaused = data.newStatus === 'paused';
  const isTerminal = ['completed', 'failed', 'cancelled'].includes(data.newStatus);

  document.querySelectorAll('.workflow-actions button').forEach(btn => {
    const label = btn.textContent.trim();
    if (label === 'Pause') btn.style.display = isRunning ? '' : 'none';
    if (label === 'Resume') btn.style.display = isPaused ? '' : 'none';
    if (label === 'Cancel') btn.style.display = (isRunning || isPaused) ? '' : 'none';
  });

  if (isTerminal) cleanupWorkflowSSE();
}

function updateStepCompleted(data) {
  const stepCard = document.querySelector(
    '.workflow-step-card[data-step-index="' + data.stepIndex + '"]'
  );
  if (!stepCard) return;

  const status = data.success ? 'completed' : 'failed';
  const badge = stepCard.querySelector('.status-badge');
  if (badge) {
    badge.textContent = _wfTitleCase(status);
    badge.className = 'status-badge status-badge-' + status;
  }
  stepCard.classList.remove('workflow-step-active');
  stepCard.setAttribute('data-step-status', status);

  const nextStep = document.querySelector(
    '.workflow-step-card[data-step-index="' + (data.stepIndex + 1) + '"]'
  );
  if (nextStep && nextStep.getAttribute('data-step-status') === 'pending') {
    nextStep.classList.add('workflow-step-active');
    const nextBadge = nextStep.querySelector('.status-badge');
    if (nextBadge) {
      nextBadge.textContent = 'Running';
      nextBadge.className = 'status-badge status-badge-running';
    }
    nextStep.setAttribute('data-step-status', 'running');
    nextStep.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
}

function updateStepTaskStatus(data) {
  if (data.stepIndex == null) return;
  const stepCard = document.querySelector(
    '.workflow-step-card[data-step-index="' + data.stepIndex + '"]'
  );
  if (!stepCard) return;

  const displayStatus = _mapTaskStatusToStepStatus(data.newStatus);
  const badge = stepCard.querySelector('.status-badge');
  if (badge) {
    badge.textContent = _wfTitleCase(displayStatus);
    badge.className = 'status-badge status-badge-' + displayStatus;
  }
  if (data.newStatus === 'running') {
    stepCard.classList.add('workflow-step-active');
  } else {
    stepCard.classList.remove('workflow-step-active');
  }
  stepCard.setAttribute('data-step-status', displayStatus);
}

function updateLoopIteration(data) {
  document.querySelectorAll('.workflow-loop-badge').forEach(badge => {
    const stepCard = badge.closest('.workflow-step-card');
    if (stepCard && badge.getAttribute('data-loop-id') === data.loopId) {
      badge.textContent = 'Iteration ' + data.iteration + '/' + data.maxIterations;
    }
  });
}

function updateParallelGroup(data) {
  (data.stepIds || []).forEach(stepId => {
    const stepCard = document.querySelector(
      '.workflow-step-card[data-step-id="' + stepId + '"]'
    );
    if (stepCard) {
      const badge = stepCard.querySelector('.status-badge');
      if (badge) {
        badge.textContent = 'Completed';
        badge.className = 'status-badge status-badge-completed';
      }
      stepCard.classList.remove('workflow-step-active');
      stepCard.setAttribute('data-step-status', 'completed');
    }
  });
}

function updateProgressBar(data) {
  const fill = document.querySelector('.workflow-progress-fill');
  const label = document.querySelector('.workflow-progress-label');
  if (!fill || !data.totalSteps) return;

  const completed = document.querySelectorAll(
    '.workflow-step-card[data-step-status="completed"]'
  ).length;
  const percent = Math.round((completed / data.totalSteps) * 100);
  fill.style.width = percent + '%';
  if (label) {
    label.innerHTML = '<span>' + completed + '</span> / <span>' + data.totalSteps + '</span> steps';
  }
}

function _mapTaskStatusToStepStatus(taskStatus) {
  switch (taskStatus) {
    case 'draft':
    case 'queued': return 'queued';
    case 'running': return 'running';
    case 'review': return 'review';
    case 'accepted':
    case 'completed': return 'completed';
    case 'failed': return 'failed';
    case 'cancelled': return 'cancelled';
    case 'rejected': return 'failed';
    default: return 'pending';
  }
}

function _wfTitleCase(s) {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
}

// Step panel expand/collapse.
document.addEventListener('click', function(e) {
  const toggle = e.target.closest('[data-step-toggle]');
  if (!toggle) return;
  const stepCard = toggle.closest('.workflow-step-card');
  if (!stepCard) return;
  const detail = stepCard.querySelector('.workflow-step-detail');
  if (!detail) return;
  const isHidden = detail.style.display === 'none';
  detail.style.display = isHidden ? '' : 'none';
  const icon = toggle.querySelector('.workflow-step-expand-icon');
  if (icon) {
    icon.classList.toggle('icon-chevron-up', isHidden);
    icon.classList.toggle('icon-chevron-down', !isHidden);
  }
});

// Context viewer expand/collapse.
document.addEventListener('click', function(e) {
  const toggle = e.target.closest('[data-context-toggle]');
  if (!toggle) return;
  const viewer = toggle.closest('.workflow-context-viewer');
  if (!viewer) return;
  const body = viewer.querySelector('.workflow-context-body');
  if (!body) return;
  const isHidden = body.style.display === 'none';
  body.style.display = isHidden ? '' : 'none';
  const icon = toggle.querySelector('.icon');
  if (icon) {
    icon.classList.toggle('icon-chevron-up', isHidden);
    icon.classList.toggle('icon-chevron-down', !isHidden);
  }
});

document.addEventListener('htmx:afterSettle', initWorkflowDetailSSE);
document.addEventListener('htmx:beforeSwap', cleanupWorkflowSSE);
