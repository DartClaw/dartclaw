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

function showToast(type, message) {
  const container = getOrCreateToastContainer();
  const toast = document.createElement('div');
  toast.className = 'toast toast-' + type;

  const safeMessage = String(message)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  toast.innerHTML =
    '<span>' + safeMessage + '</span>' +
    '<button class="toast-dismiss" aria-label="Dismiss">&times;</button>';

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
  const backdrop = document.getElementById('sidebar-backdrop');
  if (!sidebar) return;
  sidebar.classList.toggle('open', open);
  if (backdrop) backdrop.classList.toggle('open', open);
}

function initSidebar() {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;

  const menuToggle = document.querySelector('.menu-toggle');
  if (menuToggle && !menuToggle.dataset.sidebarInit) {
    menuToggle.dataset.sidebarInit = '1';
    menuToggle.addEventListener('click', () => setSidebarOpen(!sidebar.classList.contains('open')));
  }

  const closeBtn = document.querySelector('.sidebar-close');
  if (closeBtn && !closeBtn.dataset.sidebarInit) {
    closeBtn.dataset.sidebarInit = '1';
    closeBtn.addEventListener('click', () => setSidebarOpen(false));
  }

  // Click outside (overlay/backdrop) closes sidebar on mobile.
  if (!document._dartclawSidebarClickBound) {
    document._dartclawSidebarClickBound = true;
    document.addEventListener('click', (event) => {
      if (
        sidebar.classList.contains('open') &&
        !sidebar.contains(event.target) &&
        !event.target.closest('.menu-toggle')
      ) {
        setSidebarOpen(false);
      }
    });
  }

  initArchiveCollapse();
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
    '<button class="dismiss" aria-label="Dismiss">&#10005;</button>';

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
  return htmx.ajax('GET', '/sessions/' + sessionId + '/messages-html', {
    target: '#messages',
    swap: 'innerHTML',
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

    if (!confirm('Delete this session and all its messages?')) return;

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
    renderMarkdown();
    scrollToBottom();
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

  globalEventSource.onerror = () => {
    if (document.getElementById('restart-overlay')) {
      startRestartPolling();
    }
  };
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
  initSessionDelete();
  initResumeArchive();
  initInlineRename();
  typeof initMemoryViewToggle === 'function' && initMemoryViewToggle();
  typeof initMemoryDefaultTab === 'function' && initMemoryDefaultTab();
  typeof initSettingsForm === 'function' && initSettingsForm();
  typeof initChannelDetail === 'function' && initChannelDetail();
  typeof initPairingPolling === 'function' && initPairingPolling();
  initRestartBanner();
  typeof initQrFallback === 'function' && initQrFallback();
  typeof initQrCountdown === 'function' && initQrCountdown();
  renderMarkdown();
  scrollToBottom();
});
