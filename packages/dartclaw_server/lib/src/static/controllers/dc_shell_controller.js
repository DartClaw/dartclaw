import {
  apiQs,
  closeAllCustomSelects,
  getApiToken,
  initCustomSelects,
  readHtmxErrorMessage,
  renderMarkdown,
  scrollToBottom,
  showToast,
} from './shared.js';

const restartPollIntervalMs = 2000;
const restartPollTimeoutMs = 90000;

export default class DcShellController extends Stimulus.Controller {
  connect() {
    this.restartPollTimer = null;
    this.restartPollStart = null;
    this.globalEventSource = null;
    this.restartBannerDismissed = false;

    this.handleServerEvent = this.handleServerEvent.bind(this);
    this.handleDocumentClick = this.handleDocumentClick.bind(this);
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this);
    this.handleAfterSwap = this.handleAfterSwap.bind(this);
    this.handleHistoryRestore = this.handleHistoryRestore.bind(this);
    this.handleHistoryCacheMissLoad = this.handleHistoryCacheMissLoad.bind(this);
    this.applyTimelineAutoScroll = this.applyTimelineAutoScroll.bind(this);

    document.body.addEventListener('dartclaw:server-event', this.handleServerEvent);
    document.addEventListener('click', this.handleDocumentClick);
    document.addEventListener('keydown', this.handleDocumentKeydown);
    document.body.addEventListener('htmx:afterSwap', this.handleAfterSwap);
    document.body.addEventListener('htmx:historyRestore', this.handleHistoryRestore);
    document.body.addEventListener('htmx:historyCacheMissLoad', this.handleHistoryCacheMissLoad);
    document.addEventListener('htmx:afterSettle', this.applyTimelineAutoScroll);

    this.initializeShellUi();
    this.connectGlobalEvents();
    renderMarkdown();
    scrollToBottom();
    this.applyTimelineAutoScroll();
  }

  disconnect() {
    document.body.removeEventListener('dartclaw:server-event', this.handleServerEvent);
    document.removeEventListener('click', this.handleDocumentClick);
    document.removeEventListener('keydown', this.handleDocumentKeydown);
    document.body.removeEventListener('htmx:afterSwap', this.handleAfterSwap);
    document.body.removeEventListener('htmx:historyRestore', this.handleHistoryRestore);
    document.body.removeEventListener('htmx:historyCacheMissLoad', this.handleHistoryCacheMissLoad);
    document.removeEventListener('htmx:afterSettle', this.applyTimelineAutoScroll);
    if (this.globalEventSource) {
      this.globalEventSource.close();
      this.globalEventSource = null;
    }
    if (this.restartPollTimer) {
      clearInterval(this.restartPollTimer);
      this.restartPollTimer = null;
    }
  }

  handleServerEvent(event) {
    const detail = event && event.detail;
    if (!detail) return;
    if (detail.type === 'restart-required') {
      this.showRestartBanner(detail.payload || {});
    }
  }

  handleDocumentClick(event) {
    if (!event.target.closest('.custom-select')) {
      closeAllCustomSelects();
    }
    if (event.target.matches('.dismiss')) {
      event.target.closest('.banner')?.remove();
    }

    const auditRow = event.target.closest('.audit-row');
    if (auditRow) {
      this.toggleAuditRow(auditRow);
      return;
    }

    const createButton = event.target.closest('[data-session-create]');
    if (createButton) {
      event.preventDefault();
      this.createSession();
      return;
    }

    const archiveButton = event.target.closest('[data-session-archive]');
    if (archiveButton) {
      event.preventDefault();
      event.stopPropagation();
      this.archiveSession(archiveButton);
      return;
    }

    const deleteButton = event.target.closest('[data-session-delete]');
    if (deleteButton) {
      event.preventDefault();
      event.stopPropagation();
      this.deleteSession(deleteButton);
      return;
    }

    const resumeButton = event.target.closest('[data-session-resume]');
    if (resumeButton) {
      event.preventDefault();
      this.resumeSession(resumeButton);
    }
  }

  handleDocumentKeydown(event) {
    if (event.key === 'Escape') {
      closeAllCustomSelects();
    }
    if (event.key !== 'Enter' && event.key !== ' ') return;
    const row = event.target.closest('.audit-row');
    if (!row) return;
    event.preventDefault();
    this.toggleAuditRow(row);
  }

  handleAfterSwap(event) {
    const target = event.detail && event.detail.target;
    const source = event.detail && event.detail.elt;
    const isLoadEarlier = source && source.matches && source.matches('[data-load-earlier]');
    renderMarkdown();
    if (!isLoadEarlier) {
      scrollToBottom();
    }
    this.initializeShellUi();
    if (target && target.id === 'main-content') {
      target.focus({ preventScroll: true });
    }
  }

  handleHistoryRestore() {
    renderMarkdown();
    scrollToBottom();
    this.initializeShellUi();
    document.getElementById('main-content')?.focus({ preventScroll: true });
  }

  handleHistoryCacheMissLoad() {
    renderMarkdown();
    scrollToBottom();
  }

  initializeShellUi() {
    initCustomSelects(document);
    this.initThemeToggle();
    this.initSidebar();
    this.initInlineRename();
  }

  initThemeToggle() {
    const saved = localStorage.getItem('dartclaw-theme');
    if (saved === 'light') {
      document.documentElement.dataset.theme = 'light';
      const link = document.getElementById('hljs-theme');
      if (link) link.href = '/static/hljs-catppuccin-latte.css';
    }

    const button = document.querySelector('.theme-toggle');
    if (!button || button.dataset.themeInit) return;
    button.dataset.themeInit = '1';
    button.addEventListener('click', () => {
      const html = document.documentElement;
      const next = html.dataset.theme === 'light' ? '' : 'light';
      html.dataset.theme = next;
      localStorage.setItem('dartclaw-theme', next || 'dark');
      const link = document.getElementById('hljs-theme');
      if (link) {
        link.href = next === 'light' ? '/static/hljs-catppuccin-latte.css' : '/static/hljs-catppuccin-mocha.css';
      }
    });
  }

  initSidebar() {
    if (!document.getElementById('sidebar')) return;

    const menuToggle = document.querySelector('.menu-toggle');
    if (menuToggle && !menuToggle.dataset.sidebarInit) {
      menuToggle.dataset.sidebarInit = '1';
      menuToggle.addEventListener('click', () => {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar) return;
        this.setSidebarOpen(!sidebar.classList.contains('open'));
      });
    }

    const scrim = document.querySelector('.sidebar-scrim');
    if (scrim && !scrim.dataset.sidebarInit) {
      scrim.dataset.sidebarInit = '1';
      scrim.addEventListener('click', () => this.setSidebarOpen(false));
    }

    this.initArchiveCollapse();
    this.syncSidebarNavActiveState();
  }

  setSidebarOpen(open) {
    const sidebar = document.getElementById('sidebar');
    if (!sidebar) return;
    sidebar.classList.toggle('open', open);
    const menuToggle = document.querySelector('.menu-toggle');
    if (menuToggle) {
      menuToggle.setAttribute('aria-label', open ? 'Close sidebar' : 'Open sidebar');
    }
  }

  initArchiveCollapse() {
    const section = document.querySelector('.sidebar-archive-section');
    if (!section) return;
    const toggle = section.querySelector('.sidebar-archive-toggle');
    const list = section.querySelector('.sidebar-archive-list');
    if (!toggle || !list) return;

    const storageKey = 'dartclaw-sidebar-archived-collapsed';
    const isCollapsed = section.classList.contains('force-expanded')
      ? false
      : localStorage.getItem(storageKey) !== 'false';
    list.style.display = isCollapsed ? 'none' : '';
    toggle.setAttribute('aria-expanded', String(!isCollapsed));
    section.classList.toggle('expanded', !isCollapsed);

    if (toggle.dataset.archiveInit) return;
    toggle.dataset.archiveInit = '1';
    toggle.addEventListener('click', () => {
      const wasExpanded = section.classList.contains('expanded');
      list.style.display = wasExpanded ? 'none' : '';
      section.classList.toggle('expanded', !wasExpanded);
      toggle.setAttribute('aria-expanded', String(!wasExpanded));
      localStorage.setItem(storageKey, String(wasExpanded));
    });
  }

  syncSidebarNavActiveState() {
    const currentPath = window.location.pathname.replace(/\/$/, '') || '/';
    if (currentPath === '/' || currentPath.startsWith('/sessions/')) return;
    const links = document.querySelectorAll('.sidebar-nav-item');
    let bestMatchLength = -1;
    const linkPaths = [];
    links.forEach((link) => {
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

  initInlineRename() {
    const input = document.querySelector('.topbar .session-title[type="text"]');
    if (!input || input.dataset.renameInit) return;
    input.dataset.renameInit = '1';
    input.addEventListener('blur', () => this.commitRename(input));
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

  commitRename(input) {
    const newTitle = input.value.trim();
    const original = input.dataset.originalTitle;
    const sessionId = input.dataset.sessionId;
    if (!newTitle || newTitle === original || !sessionId) {
      input.value = original;
      return;
    }

    fetch('/api/sessions/' + encodeURIComponent(sessionId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: newTitle }),
    })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to rename session');
        input.dataset.originalTitle = newTitle;
        const chatArea = document.querySelector('.chat-area');
        if (chatArea) chatArea.dataset.hasTitle = 'true';
        const sidebarItem = document.querySelector(
          '.session-item-link[href*="' + CSS.escape(sessionId) + '"] .session-item-title',
        );
        if (sidebarItem) sidebarItem.textContent = newTitle;
        document.title = newTitle + ' - ' + (document.body.dataset.appName || 'DartClaw');
        showToast('success', 'Session renamed');
      })
      .catch((error) => {
        input.value = original;
        showToast('error', error.message || 'Failed to rename session');
      });
  }

  createSession() {
    fetch('/api/sessions', { method: 'POST' })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to create session');
        return response.json();
      })
      .then((data) => {
        window.location.href = '/sessions/' + data.id;
      })
      .catch((error) => showToast('error', error.message || 'Failed to create session'));
  }

  archiveSession(button) {
    const sessionId = button.dataset.sessionId;
    if (!sessionId) return;
    const sidebar = document.getElementById('sidebar');
    const wasSidebarOpen = !!(sidebar && sidebar.classList.contains('open'));
    const activeSessionId = this.currentSessionPathId();
    const headers = activeSessionId ? { 'X-Dartclaw-Active-Session-Id': activeSessionId } : {};
    const cleanup = this.bindHtmxRequestErrors(button, 'Failed to archive chat');
    const request = htmx.ajax('POST', '/api/sessions/' + encodeURIComponent(sessionId) + '/archive', {
      source: button,
      target: '#sidebar',
      swap: 'none',
      headers,
    });
    if (request && typeof request.then === 'function') {
      request.then(() => {
        if (wasSidebarOpen) this.setSidebarOpen(true);
        cleanup();
      }, cleanup);
    }
  }

  deleteSession(button) {
    const sessionId = button.dataset.sessionId;
    if (!sessionId) return;
    if (!confirm('Permanently delete this chat and all its messages?')) return;
    fetch('/api/sessions/' + encodeURIComponent(sessionId), { method: 'DELETE' })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to delete session');
        window.location.href = '/';
      })
      .catch((error) => showToast('error', error.message || 'Failed to delete session'));
  }

  resumeSession(button) {
    const sessionId = button.dataset.sessionId;
    if (!sessionId) return;
    fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/resume', { method: 'POST' })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to resume session');
        return response.json();
      })
      .then(() => window.location.reload())
      .catch((error) => showToast('error', error.message || 'Failed to resume session'));
  }

  currentSessionPathId() {
    const match = window.location.pathname.match(/^\/sessions\/([^/]+)$/);
    return match ? decodeURIComponent(match[1]) : null;
  }

  bindHtmxRequestErrors(source, fallbackMessage) {
    let cleanedUp = false;
    const cleanup = () => {
      if (cleanedUp) return;
      cleanedUp = true;
      document.body.removeEventListener('htmx:responseError', handleResponseError);
      document.body.removeEventListener('htmx:sendError', handleSendError);
    };
    const handleResponseError = (event) => {
      if (!event.detail || event.detail.elt !== source) return;
      cleanup();
      showToast('error', readHtmxErrorMessage(event.detail.xhr, fallbackMessage));
    };
    const handleSendError = (event) => {
      if (!event.detail || event.detail.elt !== source) return;
      cleanup();
      showToast('error', fallbackMessage);
    };
    document.body.addEventListener('htmx:responseError', handleResponseError);
    document.body.addEventListener('htmx:sendError', handleSendError);
    return cleanup;
  }

  toggleAuditRow(row) {
    const detailRow = row.nextElementSibling;
    if (!detailRow || !detailRow.classList.contains('audit-detail-row')) return;
    const isHidden = detailRow.style.display === 'none' || !detailRow.style.display;
    detailRow.style.display = isHidden ? 'table-row' : 'none';
    row.classList.toggle('expanded', isHidden);
    row.setAttribute('aria-expanded', String(isHidden));
  }

  applyTimelineAutoScroll() {
    const container = document.querySelector('[data-auto-scroll="true"]');
    if (container) container.scrollTop = container.scrollHeight;
  }

  connectGlobalEvents() {
    if (this.globalEventSource) return;
    const url = '/api/events' + apiQs();
    this.globalEventSource = new EventSource(url);
    this.globalEventSource.addEventListener('server_restart', () => this.showRestartOverlay());
    this.globalEventSource.addEventListener('context_warning', (event) => this.showContextWarning(event));
    this.globalEventSource.onerror = () => {
      if (document.getElementById('restart-overlay')) {
        this.startRestartPolling();
      }
    };
  }

  showContextWarning(event) {
    try {
      const data = JSON.parse(event.data);
      const currentSessionId = this.currentSessionPathId();
      if (!currentSessionId || data.sessionId !== currentSessionId) return;
      if (document.getElementById('context-warning-banner')) return;
      const banner = document.createElement('div');
      banner.id = 'context-warning-banner';
      banner.className = 'banner banner-warning';
      banner.setAttribute('role', 'status');
      banner.setAttribute('aria-live', 'polite');
      banner.innerHTML =
        '<span>' + String(data.message || 'Context window running low.')
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;') +
        '</span><button class="dismiss" aria-label="Dismiss" data-icon="x"></button>';
      document.querySelector('.chat-area')?.prepend(banner);
    } catch (_) {}
  }

  showRestartBanner(payload) {
    if (this.restartBannerDismissed) return;
    const banner = document.getElementById('restart-banner');
    const fields = document.getElementById('restart-banner-fields');
    if (!banner || !fields) return;
    const names = Array.isArray(payload.fields) ? payload.fields : [];
    fields.textContent = names.length ? names.join(', ') : 'configuration';
    banner.style.display = '';
  }

  confirmRestart() {
    if (!confirm('Restart ' + (document.body.dataset.appName || 'DartClaw') + '? Active turns will complete first.')) {
      return;
    }
    const token = getApiToken();
    fetch('/api/system/restart' + (token ? '?token=' + encodeURIComponent(token) : ''), { method: 'POST' })
      .then((response) => {
        if (response.ok) {
          this.showRestartOverlay();
          return;
        }
        response.json()
          .then((data) => alert('Restart failed: ' + (data.error?.message || 'Unknown error')))
          .catch(() => alert('Restart failed'));
      })
      .catch(() => alert('Failed to reach server'));
  }

  dismissRestartBanner() {
    const banner = document.getElementById('restart-banner');
    if (banner) banner.style.display = 'none';
    this.restartBannerDismissed = true;
  }

  showRestartOverlay() {
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
    this.startRestartPolling();
  }

  startRestartPolling() {
    if (this.restartPollTimer) return;
    this.restartPollStart = Date.now();
    this.restartPollTimer = setInterval(async () => {
      const elapsed = Date.now() - this.restartPollStart;
      if (elapsed > restartPollTimeoutMs) {
        clearInterval(this.restartPollTimer);
        this.restartPollTimer = null;
        const status = document.getElementById('restart-status');
        if (status) status.textContent = 'Server did not restart within 90s. Please check the server manually.';
        return;
      }
      try {
        const response = await fetch('/health');
        if (response.ok) {
          clearInterval(this.restartPollTimer);
          this.restartPollTimer = null;
          window.location.reload();
        }
      } catch (_) {}
    }, restartPollIntervalMs);
  }
}
