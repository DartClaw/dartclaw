import {
  apiQs,
  applyIdenticons,
  beginSessionDraftMutation,
  closeAllCustomSelects,
  conversationDraftSessionIds,
  confirmDialog,
  dismissRestartBanner as dismissRestartBannerState,
  endSessionDraftMutation,
  getApiToken,
  initCustomSelects,
  isAtBottom,
  queueToast,
  readHtmxErrorMessage,
  reconcileRestartBanner,
  renderMarkdown,
  scrollToBottom,
  showToast,
  syncSidebarSessionTitle,
  syncRestartBannerAfterSwap,
  TOAST_QUEUE_KEY,
} from './shared.js';

const restartPollIntervalMs = 2000;
const restartPollTimeoutMs = 90000;
const sidebarWidthKey = 'dartclaw-sidebar-width';
const sidebarDefaultWidth = 260;
const sidebarMinWidth = 220;
const sidebarMaxWidth = 420;

export default class DcShellController extends Stimulus.Controller {
  connect() {
    this.restartPollTimer = null;
    this.restartPollStart = null;
    this.globalEventSource = null;
    this.inboxMarkupRefresh = null;
    this.handleServerEvent = this.handleServerEvent.bind(this);
    this.handleDocumentClick = this.handleDocumentClick.bind(this);
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this);
    this.handleAfterSwap = this.handleAfterSwap.bind(this);
    this.handleFinallyRequest = this.handleFinallyRequest.bind(this);
    this.handleBeforeSwap = this.handleBeforeSwap.bind(this);
    this.captureStickyIntent = this.captureStickyIntent.bind(this);
    this.handleDrawerViewportChange = this.handleDrawerViewportChange.bind(this);
    this.handleHtmxConfirm = this.handleHtmxConfirm.bind(this);
    this.handleHtmxResponseError = this.handleHtmxResponseError.bind(this);
    this.handleHtmxError = this.handleHtmxError.bind(this);
    this.handleAuthorizationRevoked = this.handleAuthorizationRevoked.bind(this);
    this.handleConversationChanged = this.handleConversationChanged.bind(this);

    document.body.addEventListener('dartclaw:server-event', this.handleServerEvent);
    document.body.addEventListener('dartclaw:authorization-revoked', this.handleAuthorizationRevoked);
    document.body.addEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    document.body.addEventListener('htmx:response:error', this.handleHtmxResponseError);
    document.body.addEventListener('htmx:error', this.handleHtmxError);
    document.addEventListener('click', this.handleDocumentClick);
    document.addEventListener('keydown', this.handleDocumentKeydown);
    document.body.addEventListener('htmx:after:swap', this.handleAfterSwap);
    document.body.addEventListener('htmx:finally:request', this.handleFinallyRequest);
    document.body.addEventListener('htmx:before:swap', this.handleBeforeSwap);
    document.body.addEventListener('htmx:before:swap', this.captureStickyIntent);
    document.body.addEventListener('htmx:confirm', this.handleHtmxConfirm);
    // The off-canvas drawer only exists below this width.
    this.drawerViewport = window.matchMedia('(max-width: 768px)');
    this.drawerViewport.addEventListener('change', this.handleDrawerViewportChange);

    this.initializeShellUi();
    this.drainQueuedToast();
    // Global SSE (restart / context-warning events) only exists for authenticated
    // shell pages; the login page renders no sidebar and would 401 on /api/events.
    if (document.querySelector('.sidebar')) {
      this.connectGlobalEvents();
    }
    renderMarkdown();
    applyIdenticons();
    scrollToBottom(document, { force: true });
    this.applyTimelineAutoScroll({ force: true });
  }

  disconnect() {
    document.body.removeEventListener('dartclaw:server-event', this.handleServerEvent);
    document.body.removeEventListener('dartclaw:authorization-revoked', this.handleAuthorizationRevoked);
    document.body.removeEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    document.body.removeEventListener('htmx:response:error', this.handleHtmxResponseError);
    document.body.removeEventListener('htmx:error', this.handleHtmxError);
    document.removeEventListener('click', this.handleDocumentClick);
    document.removeEventListener('keydown', this.handleDocumentKeydown);
    document.body.removeEventListener('htmx:after:swap', this.handleAfterSwap);
    document.body.removeEventListener('htmx:finally:request', this.handleFinallyRequest);
    document.body.removeEventListener('htmx:before:swap', this.handleBeforeSwap);
    document.body.removeEventListener('htmx:before:swap', this.captureStickyIntent);
    document.body.removeEventListener('htmx:confirm', this.handleHtmxConfirm);
    this.drawerViewport?.removeEventListener('change', this.handleDrawerViewportChange);
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

  handleAuthorizationRevoked() {
    if (this.globalEventSource) {
      this.globalEventSource.close();
      this.globalEventSource = null;
    }
    this.setConnectionState('lost');
  }

  handleConversationChanged() {
    this.refreshInboxUi();
    this.refreshAttentionUi();
  }

  handleDocumentClick(event) {
    if (!event.target.closest('.custom-select')) {
      closeAllCustomSelects();
    }
    // One-shot page notices are removed outright; the shell's restart banner is
    // a persistent slot node that client state hides and reveals, so removing it
    // would leave a later pending restart with nothing to surface into.
    if (event.target.matches('.dismiss') && !event.target.closest('#restart-banner-slot')) {
      event.target.closest('.banner')?.remove();
    }

    const auditToggle = event.target.closest('.audit-row-toggle');
    if (auditToggle) {
      this.toggleAuditRow(auditToggle);
      return;
    }

    const createButton = event.target.closest('[data-session-create]');
    if (createButton) {
      event.preventDefault();
      this.createSession();
      return;
    }

    const settleButton = event.target.closest('[data-inbox-settle]');
    if (settleButton) {
      event.preventDefault();
      this.settleInboxRows([settleButton.closest('[data-inbox-session-id]')]);
      return;
    }

    if (event.target.closest('[data-inbox-settle-selected]')) {
      event.preventDefault();
      this.settleInboxRows([...document.querySelectorAll('[data-inbox-select]:checked')].map((input) => input.closest('[data-inbox-session-id]')));
      return;
    }

    if (event.target.closest('[data-next-attention]')) {
      event.preventDefault();
      if (this.nextAttentionSessionId) {
        location.assign('/sessions/' + encodeURIComponent(this.nextAttentionSessionId) + apiQs());
      }
      return;
    }

    if (event.target.closest('[data-inbox-clear-filter]')) {
      event.preventDefault();
      const form = document.querySelector('[data-inbox-filters]');
      form?.reset();
      this.refreshInboxUi();
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
    const sidebar = document.getElementById('sidebar');
    if (event.key === 'Tab' && sidebar?.classList.contains('open')) {
      const focusable = [...sidebar.querySelectorAll(
        'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])',
      )].filter((element) => !element.hidden && element.offsetParent !== null);
      const first = focusable[0];
      const last = focusable.at(-1);
      if (first && last && ((event.shiftKey && document.activeElement === first) ||
          (!event.shiftKey && document.activeElement === last))) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
      }
      return;
    }
    if (event.key !== 'Escape') return;
    // An open drawer is the innermost dismissible layer, so it wins; otherwise
    // Escape keeps its existing meaning for an open custom select.
    if (sidebar?.classList.contains('open')) {
      this.setSidebarOpen(false);
      return;
    }
    closeAllCustomSelects();
  }

  handleAfterSwap(event) {
    const ctx = event.detail?.ctx;
    const target = ctx?.target;
    const source = ctx?.sourceElement;
    const isLoadEarlier = source && source.matches && source.matches('[data-load-earlier]');
    const isHistoryRestore = ctx?.request?.headers?.['HX-History-Restore-Request'] === 'true';
    const stickyIntent = ctx?.dartclawStickyIntent;
    renderMarkdown();
    applyIdenticons();
    if (isHistoryRestore) {
      scrollToBottom(document, { force: true });
    } else if (!isLoadEarlier) {
      scrollToBottom(document, { stickToBottom: stickyIntent?.messages === true });
    }
    syncRestartBannerAfterSwap();
    this.initializeShellUi();
    this.restoreAuditExpansion();
    this.applyTimelineAutoScroll({ stickToBottom: stickyIntent?.timeline === true });
    this.reconcileDrawerState();
    const liveTarget = target?.isConnected ? target : (target?.id ? document.getElementById(target.id) : null);
    const focusTarget = liveTarget?.id === 'main-content'
      ? liveTarget
      : (liveTarget?.matches?.('[hx-history-elt]') ? document.getElementById('main-content') : null);
    if (focusTarget) {
      focusTarget.focus({ preventScroll: true });
    }
  }

  handleFinallyRequest(event) {
    const ctx = event.detail?.ctx;
    if (ctx?.sourceElement?.matches?.('.btn-reset') && ctx.response?.status < 400) {
      location.reload();
    }
  }

  // Adapts every `hx-confirm` attribute onto the canonical dialog, so the markup
  // never has to name a confirmation mechanism and future uses convert for free.
  async handleHtmxConfirm(event) {
    const question = event.detail?.ctx?.confirm;
    if (!question) return;
    event.preventDefault();
    const element = event.detail.ctx.sourceElement;
    const confirmed = await confirmDialog({ body: question, danger: true });
    if (!confirmed) {
      event.detail.dropRequest();
      return;
    }
    // htmx silently drops requests for detached elements, so an SSE-driven swap
    // during the dialog would otherwise turn a confirmed action into a no-op.
    if (element && !element.isConnected) {
      showToast('error', 'That action is no longer available – the page changed while you were confirming.');
      event.detail.dropRequest();
      return;
    }
    event.detail.issueRequest();
  }

  initializeShellUi() {
    initCustomSelects(document);
    this.initThemeToggle();
    this.initSidebar();
    this.initSidebarResize();
    this.initInboxUi();
    this.initAttentionUi();
    this.initInlineRename();
  }

  initThemeToggle() {
    const saved = localStorage.getItem('dartclaw-theme');
    if (saved === 'light') {
      document.documentElement.dataset.theme = 'light';
      const link = document.getElementById('hljs-theme');
      if (link) link.href = new URL('hljs-catppuccin-latte.css', link.href).href;
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
        const stylesheet = next === 'light' ? 'hljs-catppuccin-latte.css' : 'hljs-catppuccin-mocha.css';
        link.href = new URL(stylesheet, link.href).href;
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

    const sidebarClose = document.querySelector('.sidebar-close');
    if (sidebarClose && !sidebarClose.dataset.sidebarInit) {
      sidebarClose.dataset.sidebarInit = '1';
      sidebarClose.addEventListener('click', () => this.setSidebarOpen(false));
    }

    this.initArchiveCollapse();
    this.syncSidebarNavActiveState();
  }

  initSidebarResize() {
    const handle = document.querySelector('.sidebar-resize-handle');
    if (!handle || handle.dataset.resizeInit) return;
    handle.dataset.resizeInit = '1';
    const stored = Number.parseInt(localStorage.getItem(sidebarWidthKey) || '', 10);
    this.applySidebarWidth(Number.isFinite(stored) ? stored : sidebarDefaultWidth, false);
    const move = (event) => this.applySidebarWidth(event.clientX, true);
    const stop = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', stop);
    };
    handle.addEventListener('pointerdown', (event) => {
      event.preventDefault();
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', stop, { once: true });
    });
    handle.addEventListener('keydown', (event) => {
      const current = Number.parseInt(handle.getAttribute('aria-valuenow') || String(sidebarDefaultWidth), 10);
      let next = current;
      if (event.key === 'ArrowLeft') next -= 10;
      else if (event.key === 'ArrowRight') next += 10;
      else if (event.key === 'Home') next = sidebarDefaultWidth;
      else return;
      event.preventDefault();
      this.applySidebarWidth(next, true);
    });
  }

  applySidebarWidth(value, persist) {
    const width = Math.max(sidebarMinWidth, Math.min(sidebarMaxWidth, value));
    document.documentElement.style.setProperty('--sidebar-w', width + 'px');
    const handle = document.querySelector('.sidebar-resize-handle');
    if (handle) handle.setAttribute('aria-valuenow', String(width));
    if (persist) localStorage.setItem(sidebarWidthKey, String(width));
  }

  async localDraftSessionIds() {
    if (!globalThis.indexedDB) return [];
    try {
      return await conversationDraftSessionIds();
    } catch (_) {
      return [];
    }
  }

  initInboxUi() {
    const form = document.querySelector('[data-inbox-filters]');
    if (!form || form.dataset.inboxInit) return;
    form.dataset.inboxInit = '1';
    form.addEventListener('input', () => this.refreshInboxUi());
    document.querySelector('[data-settled-next]')?.addEventListener('click', () => this.refreshInboxUi(true));
    this.refreshInboxUi();
  }

  async refreshInboxUi(nextSettledPage = false) {
    const form = document.querySelector('[data-inbox-filters]');
    if (!form) return;
    const drafts = await this.localDraftSessionIds();
    const values = new FormData(form);
    const params = new URLSearchParams({
      filter: String(values.get('filter') || 'all'),
      search: String(values.get('search') || ''),
      limit: '200',
      local_draft_session_ids: drafts.join(','),
    });
    const settled = new URLSearchParams({ settled: '1', limit: '50', local_draft_session_ids: drafts.join(',') });
    const nextButton = document.querySelector('[data-settled-next]');
    if (nextSettledPage && nextButton?.dataset.cursor) settled.set('cursor', nextButton.dataset.cursor);
    try {
      const [activeResponse, settledResponse] = await Promise.all([
        fetch('/api/inbox?' + params),
        fetch('/api/inbox?' + settled),
      ]);
      if (!activeResponse.ok || !settledResponse.ok) throw new Error('Inbox request failed');
      const active = await activeResponse.json();
      const settledPage = await settledResponse.json();
      const missingActiveRow = active.entries.some((entry) =>
        entry.session.type === 'user'
        && !document.querySelector('[data-inbox-session-id="' + CSS.escape(entry.session.id) + '"]'));
      if (missingActiveRow) {
        await this.refreshInboxMarkup(values);
        return;
      }
      this.nextAttentionSessionId = active.next_attention_session_id;
      document.querySelector('[data-inbox-total]').textContent = String(active.filtered_total);
      document.querySelector('[data-waiting-total]').textContent = active.waiting_total ? '· ' + active.waiting_total : '';
      for (const row of document.querySelectorAll('[data-inbox-session-id]')) row.hidden = true;
      for (const entry of active.entries) {
        const row = document.querySelector('[data-inbox-session-id="' + CSS.escape(entry.session.id) + '"]');
        if (!row) continue;
        row.hidden = false;
        row.dataset.conversationRevision = String(entry.conversation_revision);
        const states = ['unread', 'waiting', 'running', 'failed', 'done', 'local_draft'].filter((state) => entry[state]);
        row.dataset.inboxState = states.join(' ');
        row.setAttribute('aria-label', states.length ? states.join(', ') : 'idle');
        const stateLabel = row.querySelector('[data-inbox-state-label]');
        if (stateLabel) stateLabel.textContent = states.map((state) => state.replace('_', ' ')).join(' · ');
        const lineage = row.querySelector('[data-inbox-lineage]');
        if (lineage) lineage.textContent = entry.parent_session_id ? 'Fork' : '';
        const elapsed = row.querySelector('[data-inbox-running-elapsed]');
        if (elapsed) elapsed.textContent = entry.running_since ? this.elapsedLabel(entry.running_since) : '';
      }
      const visibleCount = active.entries.filter((entry) => document.querySelector('[data-inbox-session-id="' + CSS.escape(entry.session.id) + '"]')).length;
      const empty = document.querySelector('[data-inbox-empty]');
      if (empty) empty.hidden = visibleCount !== 0;
      this.renderSettled(settledPage, nextSettledPage);
      this.renderDeviceDrafts(drafts, [...active.entries, ...settledPage.entries]);
      showToast('info', '', { sourceRef: 'conversation-inbox', recovered: true });
    } catch (_) {
      showToast('error', 'Inbox updates are unavailable', { sourceRef: 'conversation-inbox', persistent: true });
    }
  }

  async refreshInboxMarkup(values) {
    if (this.inboxMarkupRefresh) return this.inboxMarkupRefresh;
    this.inboxMarkupRefresh = (async () => {
      const response = await fetch(location.href, { headers: { accept: 'text/html' } });
      if (!response.ok) throw new Error('Sidebar request failed');
      const next = new DOMParser().parseFromString(await response.text(), 'text/html').querySelector('#sidebar');
      const current = document.getElementById('sidebar');
      if (!next || !current) throw new Error('Sidebar response is incomplete');
      current.replaceWith(next);
      const form = next.querySelector('[data-inbox-filters]');
      if (form) {
        form.elements.search.value = String(values.get('search') || '');
        form.elements.filter.value = String(values.get('filter') || 'all');
      }
      this.initializeShellUi();
      applyIdenticons(next);
    })();
    try {
      return await this.inboxMarkupRefresh;
    } finally {
      this.inboxMarkupRefresh = null;
    }
  }

  elapsedLabel(startedAt) {
    const elapsedSeconds = Math.max(0, Math.floor((Date.now() - Date.parse(startedAt)) / 1000));
    if (elapsedSeconds < 60) return 'Running ' + elapsedSeconds + 's';
    return 'Running ' + Math.floor(elapsedSeconds / 60) + 'm';
  }

  async settleInboxRows(rows) {
    const members = rows.filter(Boolean).map((row) => ({
      session_id: row.dataset.inboxSessionId,
      conversation_revision: Number.parseInt(row.dataset.conversationRevision || '', 10),
    })).filter((member) => member.session_id && Number.isInteger(member.conversation_revision));
    if (!members.length) {
      this.announceInbox('Select at least one conversation');
      return;
    }
    const drafts = await this.localDraftSessionIds();
    const response = await fetch('/api/inbox/settle', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ members, local_draft_session_ids: drafts }),
    });
    if (!response.ok) {
      this.announceInbox('Conversations could not be settled');
      return;
    }
    const body = await response.json();
    const accepted = body.results.filter((result) => result.accepted).length;
    const rejected = body.results.length - accepted;
    this.announceInbox(accepted + ' settled' + (rejected ? ', ' + rejected + ' unchanged' : ''));
    await this.refreshInboxUi();
  }

  announceInbox(message) {
    const region = document.querySelector('[data-inbox-announcer]');
    if (region) region.textContent = message;
  }

  renderSettled(page, append) {
    const list = document.querySelector('[data-settled-list]');
    if (!list) return;
    if (!append) list.replaceChildren();
    for (const entry of page.entries) {
      const row = document.createElement('div');
      row.className = 'session-item session-item-settled';
      const link = document.createElement('a');
      link.className = 'session-item-link';
      link.href = '/sessions/' + encodeURIComponent(entry.session.id);
      link.textContent = (entry.session.title || 'Untitled draft') + ' · settled';
      const restore = document.createElement('button');
      restore.type = 'button';
      restore.className = 'btn btn-ghost btn-sm';
      restore.textContent = 'Restore';
      restore.addEventListener('click', () => this.restoreSettled(entry));
      row.append(link, restore);
      list.appendChild(row);
    }
    const total = document.querySelector('[data-settled-total]');
    if (total) total.textContent = '· ' + page.total;
    const next = document.querySelector('[data-settled-next]');
    if (next) {
      next.hidden = !page.next_cursor;
      next.dataset.cursor = page.next_cursor || '';
    }
  }

  async restoreSettled(entry) {
    const response = await fetch('/api/inbox/' + encodeURIComponent(entry.session.id) + '/restore', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ conversation_revision: entry.conversation_revision }),
    });
    if (response.ok) location.reload();
    else showToast('error', 'Conversation changed before it could be restored');
  }

  renderDeviceDrafts(draftIds, entries) {
    const section = document.querySelector('[data-device-drafts]');
    const list = document.querySelector('[data-device-draft-list]');
    if (!section || !list) return;
    list.replaceChildren();
    for (const id of draftIds) {
      const entry = entries.find((candidate) => candidate.session.id === id);
      const link = document.createElement('a');
      link.className = 'session-item-link';
      link.href = '/sessions/' + encodeURIComponent(id);
      link.textContent = (entry?.session?.title || 'Untitled draft') + (entry?.session?.settledAt ? ' · settled remotely' : '');
      list.appendChild(link);
    }
    section.hidden = draftIds.length === 0;
  }

  initAttentionUi() {
    const toggle = document.querySelector('[data-attention-toggle]');
    if (!toggle || toggle.dataset.attentionInit) return;
    toggle.dataset.attentionInit = '1';
    toggle.addEventListener('click', () => {
      const panel = document.querySelector('[data-attention-panel]');
      panel.hidden = !panel.hidden;
      toggle.setAttribute('aria-expanded', String(!panel.hidden));
      if (!panel.hidden) {
        panel.querySelector('a,button')?.focus();
        this.markVisibleAttentionRead();
      }
    });
    this.refreshAttentionUi();
  }

  async refreshAttentionUi(cursor = null) {
    try {
      const response = await fetch('/api/attention?' + new URLSearchParams({ limit: '50', ...(cursor ? { cursor } : {}) }));
      if (!response.ok) throw new Error('Attention request failed');
      const page = await response.json();
      this.attentionItems = page.items;
      const list = document.querySelector('[data-attention-list]');
      if (!list) return;
      list.replaceChildren();
      for (const item of page.items) list.appendChild(this.attentionRow(item));
      const unread = document.querySelector('[data-attention-unread]');
      if (unread) unread.textContent = page.unread_total ? String(page.unread_total) : '';
      const next = document.querySelector('[data-attention-panel] [data-attention-next]');
      if (next) {
        next.hidden = !page.next_cursor;
        next.onclick = () => this.refreshAttentionUi(page.next_cursor);
      }
      showToast('info', '', { sourceRef: 'attention-feed', recovered: true });
    } catch (_) {
      showToast('error', 'Attention updates are unavailable', { sourceRef: 'attention-feed', persistent: true });
    }
  }

  attentionRow(item) {
    const row = document.createElement('article');
    row.className = 'notif-item' + (item.unread ? ' notif-item--unread' : '');
    row.dataset.eventId = item.event_id;
    const dot = document.createElement('span');
    dot.className = 'status-dot ' + (item.action_available ? 'status-dot--attention' : item.status === 'failed' ? 'status-dot--error' : 'status-dot--idle');
    dot.setAttribute('aria-hidden', 'true');
    const body = document.createElement('div');
    body.className = 'notif-item-body';
    const title = document.createElement('strong');
    title.className = 'notif-item-title';
    title.textContent = item.title;
    const detail = document.createElement('span');
    detail.className = 'notif-item-detail';
    detail.textContent = item.detail;
    const context = document.createElement('span');
    context.className = 'attention-item-context';
    context.textContent = [item.source, item.status].filter(Boolean).join(' · ');
    const actions = document.createElement('div');
    actions.className = 'attention-item-actions';
    const link = document.createElement('a');
    const query = new URLSearchParams();
    if (item.message_id) query.set('message', item.message_id);
    const token = getApiToken();
    if (token) query.set('token', token);
    const recordTarget = item.record_id ? '#record-' + encodeURIComponent(item.record_id) : '';
    link.href = '/sessions/' + encodeURIComponent(item.session_id) + (query.size ? '?' + query : '') + recordTarget;
    link.textContent = 'Open transcript';
    actions.appendChild(link);
    if (item.action_available) {
      for (const [label, approved] of [['Approve', true], ['Reject', false]]) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = label;
        button.addEventListener('click', () => this.resolveAttention(item, approved));
        actions.appendChild(button);
      }
    }
    if (item.dismissible) {
      const dismiss = document.createElement('button');
      dismiss.type = 'button';
      dismiss.textContent = 'Dismiss';
      dismiss.addEventListener('click', () => this.updateAttentionMarker('/api/attention/dismiss', item));
      actions.appendChild(dismiss);
    }
    const occurred = document.createElement('time');
    occurred.className = 'notif-item-time';
    occurred.dateTime = item.occurred_at;
    occurred.textContent = new Date(item.occurred_at).toLocaleString();
    body.append(title, detail, context, actions);
    row.append(dot, body, occurred);
    return row;
  }

  async markVisibleAttentionRead() {
    const newestBySession = new Map();
    for (const item of this.attentionItems || []) {
      if (item.unread && !newestBySession.has(item.session_id)) newestBySession.set(item.session_id, item);
    }
    await Promise.all([...newestBySession.values()].map((item) => this.updateAttentionMarker('/api/attention/read', item, false)));
    if (newestBySession.size) this.refreshAttentionUi();
  }

  async updateAttentionMarker(path, item, refresh = true) {
    const response = await fetch(path, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        event_id: item.event_id,
        session_id: item.session_id,
        conversation_revision: item.conversation_revision,
      }),
    });
    if (response.ok && refresh) this.refreshAttentionUi();
    return response.ok;
  }

  async resolveAttention(item, approved) {
    const response = await fetch('/api/attention/action', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        event_id: item.event_id, session_id: item.session_id, attempt_id: item.attempt_id,
        turn_id: item.turn_id, request_id: item.request_id,
        conversation_revision: item.conversation_revision, approved,
      }),
    });
    if (response.ok) this.refreshAttentionUi();
    else showToast('error', 'That attention action is no longer available');
  }

  /// Re-derives the drawer's inert boundary from the DOM.
  ///
  /// Navigating from an open drawer replaces `#sidebar` out-of-band with server
  /// markup that carries no `.open`, so the drawer closes without ever calling
  /// [setSidebarOpen]. Left alone, `.shell-main` stays `inert` with
  /// `.menu-toggle` — the only control that could undo it — inside that
  /// boundary, and the page has no recovery short of a reload.
  ///
  /// Idempotent: [setSidebarOpen] short-circuits before moving focus when the
  /// state is already what it asks for, so the repeat settles per navigation
  /// cost nothing.
  reconcileDrawerState() {
    if (document.getElementById('sidebar')?.classList.contains('open')) return;
    this.setSidebarOpen(false);
  }

  /// Above the drawer breakpoint the rail is permanent and `.menu-toggle` is
  /// hidden, so an "open" drawer carried across a resize would inert the page
  /// with nothing left to close it.
  handleDrawerViewportChange(event) {
    if (!event.matches) this.setSidebarOpen(false);
  }

  setSidebarOpen(open) {
    const sidebar = document.getElementById('sidebar');
    if (!sidebar) return;
    const wasOpen = sidebar.classList.contains('open');
    sidebar.classList.toggle('open', open);
    const scrim = document.querySelector('.sidebar-scrim');
    if (scrim) {
      scrim.setAttribute('aria-hidden', String(!open));
      // Pointer-only: the drawer's own close button and Escape are the keyboard
      // paths, so the scrim never becomes a sequential tab stop.
      scrim.tabIndex = -1;
    }
    const menuToggle = document.querySelector('.menu-toggle');
    if (menuToggle) {
      menuToggle.setAttribute('aria-label', open ? 'Close sidebar' : 'Open sidebar');
      menuToggle.setAttribute('aria-expanded', String(open));
      menuToggle.setAttribute('data-icon', open ? 'x' : 'menu');
    }
    // Inert the whole right column rather than a selector list, so a visible
    // restart banner's controls are covered without a second focus trap.
    for (const region of [document.querySelector('.skip-link'), document.querySelector('.shell-main')]) {
      region?.toggleAttribute('inert', open);
    }
    // Only on a real transition: a no-op close (shell re-init, restore) must not
    // yank focus to a control the user never touched.
    if (open === wasOpen) return;
    if (open) {
      document.querySelector('.sidebar-close')?.focus();
    } else {
      menuToggle?.focus();
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
    list.hidden = isCollapsed;
    toggle.setAttribute('aria-expanded', String(!isCollapsed));
    section.classList.toggle('expanded', !isCollapsed);

    if (toggle.dataset.archiveInit) return;
    toggle.dataset.archiveInit = '1';
    toggle.addEventListener('click', () => {
      const wasExpanded = section.classList.contains('expanded');
      list.hidden = wasExpanded;
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

    beginSessionDraftMutation(sessionId);
    fetch('/api/sessions/' + encodeURIComponent(sessionId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: newTitle }),
    })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to rename session');
        input.dataset.originalTitle = newTitle;
        const chatArea = document.querySelector('.chat-area');
        if (chatArea) {
          chatArea.dataset.hasTitle = 'true';
          delete chatArea.dataset.newChatDraft;
        }
        syncSidebarSessionTitle(sessionId, newTitle);
        document.title = newTitle + ' - ' + (document.body.dataset.appName || 'DartClaw');
        showToast('success', 'Session renamed');
      })
      .catch((error) => {
        input.value = original;
        showToast('error', error.message || 'Failed to rename session');
      })
      .finally(() => endSessionDraftMutation(sessionId));
  }

  createSession() {
    if (this.sessionCreatePromise) return this.sessionCreatePromise;

    const createButtons = Array.from(document.querySelectorAll('[data-session-create]'));
    for (const button of createButtons) {
      button.disabled = true;
      button.setAttribute('aria-busy', 'true');
    }

    this.sessionCreatePromise = this.openNewChatAfterPendingMutation()
      .catch((error) => {
        showToast('error', error.message || 'Failed to create session');
      })
      .finally(() => {
        this.sessionCreatePromise = null;
        for (const button of createButtons) {
          button.disabled = false;
          button.removeAttribute('aria-busy');
        }
      });
    return this.sessionCreatePromise;
  }

  async openNewChatAfterPendingMutation() {
    await this.waitForSessionDraftMutation();
    if (this.focusCurrentNewChatDraft()) return;

    const response = await fetch('/api/sessions/open', { method: 'POST' });
    if (!response.ok) throw new Error('Failed to create session');
    const data = await response.json();
    if (data.id === this.currentSessionPathId() && this.focusCurrentNewChatDraft()) return;
    window.location.href = '/sessions/' + data.id;
  }

  waitForSessionDraftMutation() {
    const mutationPending = () => {
      const chatArea = document.querySelector('.chat-area');
      return chatArea?.dataset.sessionId === this.currentSessionPathId() &&
        Number.parseInt(chatArea.dataset.sessionMutationPending || '0', 10) > 0;
    };
    if (!mutationPending()) return Promise.resolve();

    return new Promise((resolve) => {
      const handleComplete = () => {
        if (mutationPending()) return;
        document.removeEventListener('dartclaw:session-draft-mutation-complete', handleComplete);
        resolve();
      };
      document.addEventListener('dartclaw:session-draft-mutation-complete', handleComplete);
      handleComplete();
    });
  }

  focusCurrentNewChatDraft() {
    const chatArea = document.querySelector('.chat-area[data-new-chat-draft="true"]');
    if (!chatArea || chatArea.dataset.sessionId !== this.currentSessionPathId()) return false;
    if (chatArea.querySelector('#messages .msg')) return false;
    this.setSidebarOpen(false);
    chatArea.querySelector('#message-input')?.focus();
    return true;
  }

  archiveSession(button) {
    const sessionId = button.dataset.sessionId;
    if (!sessionId) return;
    const sidebar = document.getElementById('sidebar');
    const wasSidebarOpen = !!(sidebar && sidebar.classList.contains('open'));
    const activeSessionId = this.currentSessionPathId();
    const headers = activeSessionId ? { 'X-Dartclaw-Active-Session-Id': activeSessionId } : {};
    // Failures are reported by the body-level htmx error listeners; this only
    // restores the sidebar the swap collapsed.
    const request = htmx.ajax('POST', '/api/sessions/' + encodeURIComponent(sessionId) + '/archive', {
      source: button,
      target: '#sidebar',
      swap: 'none',
      headers,
    });
    if (request && typeof request.then === 'function') {
      request.then(() => {
        if (wasSidebarOpen) this.setSidebarOpen(true);
        // Failures are already reported by the body-level listeners; this arm
        // only stops an unhandled rejection.
      }, () => {});
    }
  }

  async deleteSession(button) {
    // Read the dataset before awaiting — the row can be swapped out under us.
    const sessionId = button.dataset.sessionId;
    const sessionTitle = button.dataset.sessionTitle;
    if (!sessionId) return;
    const confirmed = await confirmDialog({
      title: 'Delete chat',
      body: sessionTitle
        ? 'Permanently delete "' + sessionTitle + '" and all its messages?'
        : 'Permanently delete this chat and all its messages?',
      confirmLabel: 'Delete',
      danger: true,
    });
    if (!confirmed) return;
    fetch('/api/sessions/' + encodeURIComponent(sessionId), { method: 'DELETE' })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to delete session');
        // Queued, not shown: the navigation below destroys this document.
        queueToast('success', 'Chat deleted');
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

  drainQueuedToast() {
    let raw = null;
    try {
      raw = sessionStorage.getItem(TOAST_QUEUE_KEY);
      // Cleared in the same read, so a second navigation cannot repeat it.
      sessionStorage.removeItem(TOAST_QUEUE_KEY);
    } catch (_) {
      return;
    }
    if (!raw) return;
    try {
      const queued = JSON.parse(raw);
      if (queued && queued.message) showToast(queued.type || 'success', queued.message);
    } catch (_) {}
  }

  // Sole owner of HTMX failure reporting. Every hx-* site on the page is
  // covered without a template edit, and no call site may add its own pair —
  // two listeners on the same event paint two toasts for one failure.
  handleHtmxResponseError(event) {
    if (!event.detail) return;
    showToast('error', readHtmxErrorMessage(event.detail.ctx, 'Request failed'));
  }

  handleHtmxError(event) {
    if (!event.detail) return;
    showToast('error', event.detail.error?.message || 'Could not reach the server');
  }

  toggleAuditRow(toggle) {
    const detailRow = document.getElementById(toggle.getAttribute('aria-controls') || '');
    if (!detailRow || !detailRow.classList.contains('audit-detail-row')) return;
    const expand = detailRow.hidden;
    detailRow.hidden = !expand;
    toggle.setAttribute('aria-expanded', String(expand));
    // A collapse is the reader retracting their intent, so the restore key goes
    // with it. Left set, the next swap from anywhere on the page – the status
    // region above refreshes on its own 30s timer – would re-open the row they
    // just closed.
    this.expandedAuditKey = expand ? toggle.dataset.auditKey : null;
  }

  // The audit log has no row id, so an expanded row is tracked by the
  // presentation key the server derives from the fields it renders. Captured
  // before the 30s poll replaces the table and re-applied only if the same key
  // comes back – an entry that dropped out of the page leaves every row closed
  // rather than transferring its expansion to whichever row took its place.
  handleBeforeSwap(event) {
    const target = event.detail?.ctx?.target;
    if (!target || target.id !== 'audit-table-container') return;
    const open = target.querySelector('.audit-row-toggle[aria-expanded="true"]');
    this.expandedAuditKey = open ? open.dataset.auditKey : null;
  }

  restoreAuditExpansion() {
    if (!this.expandedAuditKey) return;
    const toggle = document.querySelector(
      '.audit-row-toggle[data-audit-key="' + CSS.escape(this.expandedAuditKey) + '"]',
    );
    if (toggle && toggle.getAttribute('aria-expanded') !== 'true') this.toggleAuditRow(toggle);
  }

  applyTimelineAutoScroll({ force = false, stickToBottom = false } = {}) {
    if (!force && !stickToBottom) return;
    const container = document.querySelector('[data-auto-scroll="true"]');
    if (container) container.scrollTop = container.scrollHeight;
  }

  /// Records, before htmx mutates the DOM, whether each shared scroll region was
  /// at its bottom. Content growth changes that distance, so measuring after the
  /// swap would report the reader's new position rather than their intent.
  captureStickyIntent(event) {
    if (!event.detail?.ctx) return;
    event.detail.ctx.dartclawStickyIntent = {
      messages: isAtBottom(document.querySelector('.messages')),
      timeline: isAtBottom(document.querySelector('[data-auto-scroll="true"]')),
    };
  }

  connectGlobalEvents() {
    if (this.globalEventSource) return;
    const url = '/api/events' + apiQs();
    this.globalEventSource = new EventSource(url);
    this.globalEventSource.addEventListener('server_restart', () => this.showRestartOverlay());
    this.globalEventSource.addEventListener('context_warning', (event) => this.showContextWarning(event));
    this.globalEventSource.addEventListener('conversation_changed', (event) => {
      try {
        document.body.dispatchEvent(new CustomEvent('dartclaw:conversation-changed', { detail: JSON.parse(event.data) }));
      } catch (_) {}
    });
    this.globalEventSource.onopen = () => this.setConnectionState('live');
    this.globalEventSource.onerror = () => {
      if (document.getElementById('restart-overlay')) {
        this.startRestartPolling();
        return;
      }
      this.setConnectionState('lost');
    };
  }

  // A live pulse or a sweeping scan-bar is a claim that the view is current.
  // While the event stream is down that claim is false, so the shell records
  // the state, says so in words, and app.css stops the animations that would
  // otherwise keep asserting freshness.
  setConnectionState(state) {
    const shell = document.querySelector('.shell');
    if (shell) shell.dataset.connection = state;

    const existing = document.getElementById('connection-lost-banner');
    if (state !== 'lost') {
      if (existing) existing.remove();
      return;
    }
    if (existing) return;
    const host = document.getElementById('main-content');
    if (!host) return;
    const banner = document.createElement('div');
    banner.id = 'connection-lost-banner';
    banner.className = 'banner banner-warning';
    banner.setAttribute('role', 'status');
    banner.setAttribute('aria-live', 'polite');
    banner.innerHTML = '<span>Live updates disconnected. Reconnecting…</span>';
    host.prepend(banner);
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
    reconcileRestartBanner(Array.isArray(payload.fields) ? payload.fields : []);
  }

  async confirmRestart() {
    const appName = document.body.dataset.appName || 'DartClaw';
    // Restarting is recoverable, so this is the non-destructive confirmation:
    // no glyph, plain confirm button — see DESIGN.md § Feedback.
    const confirmed = await confirmDialog({
      title: 'Restart ' + appName,
      body: 'Restart ' + appName + '? Active turns will complete first.',
      confirmLabel: 'Restart',
    });
    if (!confirmed) return;
    const token = getApiToken();
    fetch('/api/system/restart' + (token ? '?token=' + encodeURIComponent(token) : ''), { method: 'POST' })
      .then((response) => {
        if (response.ok) {
          this.showRestartOverlay();
          return;
        }
        response.json()
          .then((data) => showToast('error', 'Restart failed: ' + (data.error?.message || 'Unknown error')))
          .catch(() => showToast('error', 'Restart failed'));
      })
      .catch(() => showToast('error', 'Failed to reach server'));
  }

  dismissRestartBanner() {
    dismissRestartBannerState();
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
        <div class="claw-loader" aria-label="Server is restarting"><span></span><span></span><span></span></div>
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
