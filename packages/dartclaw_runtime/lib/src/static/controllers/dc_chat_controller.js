import {
  beginSessionDraftMutation,
  endSessionDraftMutation,
  escapeHtml,
  isAtBottom,
  readHtmxErrorMessage,
  renderMarkdown,
  scrollToBottom,
  showBanner,
  showToast,
  syncSidebarSessionTitle,
} from './shared.js';

export default class DcChatController extends Stimulus.Controller {
  connect() {
    this.attachments = [];
    this.references = [];
    this.filteredReferences = [];
    this.activeReferenceIndex = 0;
    this.streaming = false;
    this.chatRequestPending = false;
    this.recoveryActive = false;
    this.turnFinalized = false;
    this.canCancel = false;
    this.turnStatusTimer = null;
    this.turnStatusPollGeneration = 0;
    this.streamRecoveryTurnId = null;
    this.conversationReady = false;
    this.conversationRevision = 0;
    this.ordinaryControls = true;
    this.maxAttachmentBytes = 0;
    this.draftRevisionId = this.generateClientId();
    this.draftTouched = false;
    this.submittedRevisionId = null;
    this.saveTimer = null;
    this.pendingConflict = null;
    this.queueItems = new Map();
    this.paginationAnchor = null;
    this.paginationAnchorTop = null;
    this.handleBeforeRequest = this.handleBeforeRequest.bind(this);
    this.handleFinallyRequest = this.handleFinallyRequest.bind(this);
    this.handleSseBeforeMessage = this.handleSseBeforeMessage.bind(this);
    this.handleSseClose = this.handleSseClose.bind(this);
    this.handleLoadEarlierClick = this.handleLoadEarlierClick.bind(this);
    this.handleTextareaInput = this.handleTextareaInput.bind(this);
    this.handleTextareaKeydown = this.handleTextareaKeydown.bind(this);
    this.handleSendButtonClick = this.handleSendButtonClick.bind(this);
    this.handleConversationChanged = this.handleConversationChanged.bind(this);
    this.handleConnectivityChange = this.handleConnectivityChange.bind(this);

    document.body.addEventListener('htmx:before:request', this.handleBeforeRequest);
    document.body.addEventListener('htmx:finally:request', this.handleFinallyRequest);
    document.body.addEventListener('htmx:sse:before:message', this.handleSseBeforeMessage);
    document.body.addEventListener('htmx:sse:close', this.handleSseClose);
    this.element.addEventListener('click', this.handleLoadEarlierClick);
    document.body.addEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    window.addEventListener('online', this.handleConnectivityChange);
    window.addEventListener('offline', this.handleConnectivityChange);

    this.initTextarea();
    this.sendButton?.addEventListener('click', this.handleSendButtonClick);
    this.updateSendState();
    renderMarkdown(this.element);
    scrollToBottom(this.element, { force: true });
    this.initializeConversationState();
    this.initializeDraftStorage();
  }

  disconnect() {
    document.body.removeEventListener('htmx:before:request', this.handleBeforeRequest);
    document.body.removeEventListener('htmx:finally:request', this.handleFinallyRequest);
    document.body.removeEventListener('htmx:sse:before:message', this.handleSseBeforeMessage);
    document.body.removeEventListener('htmx:sse:close', this.handleSseClose);
    this.element.removeEventListener('click', this.handleLoadEarlierClick);
    document.body.removeEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    window.removeEventListener('online', this.handleConnectivityChange);
    window.removeEventListener('offline', this.handleConnectivityChange);
    this._stopTurnStatusPolling();
    this.streamRecoveryTurnId = null;
    document.body.classList.remove('streaming');
    this.form?.classList.remove('composer--streaming');
    const textarea = this.textarea;
    if (textarea) {
      textarea.removeEventListener('input', this.handleTextareaInput);
      textarea.removeEventListener('keydown', this.handleTextareaKeydown);
    }
    this.sendButton?.removeEventListener('click', this.handleSendButtonClick);
    clearTimeout(this.saveTimer);
    this.draftChannel?.close();
  }

  get textarea() {
    return this.element.querySelector('#message-input');
  }

  get sendButton() {
    return this.element.querySelector('#send-btn');
  }

  get form() {
    return this.element.querySelector('#chat-form');
  }

  get contextTray() {
    return this.element.querySelector('[data-dc-chat-target="contextTray"]');
  }

  get referencePalette() {
    return this.element.querySelector('[data-dc-chat-target="referencePalette"]');
  }

  get attachmentsInput() {
    return this.element.querySelector('[data-dc-chat-target="attachmentsInput"]');
  }

  get referencesInput() {
    return this.element.querySelector('[data-dc-chat-target="referencesInput"]');
  }

  get recovery() {
    return this.element.querySelector('[data-dc-chat-target="recovery"]');
  }

  get saveStatus() {
    return this.element.querySelector('[data-dc-chat-target="saveStatus"]');
  }

  get liveStatus() {
    return this.element.querySelector('[data-dc-chat-target="liveStatus"]');
  }

  get recoveryActions() {
    return this.element.querySelector('[data-dc-chat-target="recoveryActions"]');
  }

  get conflictAction() {
    return this.element.querySelector('[data-dc-chat-target="conflictAction"]');
  }

  get queue() {
    return this.element.querySelector('[data-dc-chat-target="queue"]');
  }

  get stopButton() {
    return this.element.querySelector('[data-dc-chat-target="stopButton"]');
  }

  get steerButton() {
    return this.element.querySelector('[data-dc-chat-target="steerButton"]');
  }

  get submissionIdInput() {
    return this.element.querySelector('[data-dc-chat-target="submissionIdInput"]');
  }

  get revisionIdInput() {
    return this.element.querySelector('[data-dc-chat-target="revisionIdInput"]');
  }

  get sessionId() {
    return this.element.dataset.sessionId;
  }

  initTextarea() {
    const textarea = this.textarea;
    if (!textarea) return;
    textarea.addEventListener('input', this.handleTextareaInput);
    textarea.addEventListener('keydown', this.handleTextareaKeydown);
  }

  handleTextareaInput() {
    const textarea = this.textarea;
    if (!textarea) return;
    textarea.style.height = 'auto';
    textarea.style.height = Math.min(textarea.scrollHeight, Math.max(96, (globalThis.innerHeight || 800) * 0.32)) + 'px';
    this.draftTouched = true;
    this.draftRevisionId = this.generateClientId();
    this.draftSubmissionId = this.generateClientId();
    this.hideRecovery();
    this.maybeOpenReferencePalette();
    this.updateSendState();
    this.scheduleDraftSave();
  }

  handleTextareaKeydown(event) {
    if (this.referencePalette && !this.referencePalette.hidden && this.handlePaletteKey(event)) return;
    if (event.isComposing) return;
    if (!(event.ctrlKey || event.metaKey) || event.key !== 'Enter') return;
    event.preventDefault();
    this.form?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  }

  updateSendState() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (button) {
      const hasInput = Boolean(textarea && (textarea.value.trim() || this.attachments.length || this.references.length));
      const richReady = !this.attachments.some((attachment) => attachment.state !== 'ready') &&
        !(textarea?.value || '').match(/(^|\s)@[\w./:-]+/);
      const online = typeof navigator === 'undefined' || navigator.onLine !== false;
      button.disabled = !hasInput || !richReady || !online || !this.conversationReady || this.chatRequestPending;
      button.type = 'submit';
      const canQueue = this.streaming && this.ordinaryControls !== false;
      button.textContent = canQueue ? 'Queue' : 'Send';
      button.setAttribute('aria-label', canQueue ? 'Queue message' : 'Send message');
      button.title = canQueue ? 'Queue this message' : 'Send message';
      button.classList.remove('btn-stop');
    }
    if (this.stopButton) {
      this.stopButton.hidden = !this.streaming;
      this.stopButton.disabled = !this.canCancel;
    }
    if (this.steerButton) {
      this.steerButton.hidden = !this.streaming || this.ordinaryControls === false;
      this.steerButton.disabled = !this.canCancel;
    }
  }

  disableInput() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (textarea) {
      textarea.disabled = false;
      textarea.placeholder = 'Write the next message while the agent works…';
    }
    this.streaming = true;
    this.turnFinalized = false;
    document.body.classList.add('streaming');
    this.form?.classList.add('composer--streaming');
    if (button) button.disabled = false;
    this.closePalettes();
    this._startTurnStatusPolling();
    this.updateSendState();
  }

  enableInput() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (textarea) {
      textarea.disabled = false;
      textarea.placeholder = 'Type a message...';
    }
    this.streaming = false;
    document.body.classList.remove('streaming');
    this.form?.classList.remove('composer--streaming');
    this._stopTurnStatusPolling();
    if (button) button.disabled = !textarea || !textarea.value.trim();
    this.updateSendState();
  }

  isChatFormRequest(event) {
    return event.detail?.ctx?.sourceElement?.id === 'chat-form';
  }

  handleBeforeRequest(event) {
    if (this.isChatFormRequest(event)) {
      if (!this.canSubmitRichInput()) {
        event.preventDefault();
        return;
      }
      this.chatRequestPending = true;
      this.submittedRevisionId = this.draftRevisionId;
      this.submittedDraft = this.currentDraft();
      if (this.submissionIdInput) this.submissionIdInput.value = this.submittedDraft.submissionId;
      if (this.revisionIdInput) this.revisionIdInput.value = this.submittedRevisionId;
      this.hideRecovery();
      beginSessionDraftMutation(this.sessionId);
      this.setSaveStatus('Submitting…');
      this.updateSendState();
    }
  }

  handleFinallyRequest(event) {
    const ctx = event.detail?.ctx;
    if (this.isChatFormRequest(event)) {
      if (!this.chatRequestPending) return;
      this.chatRequestPending = false;
      endSessionDraftMutation(this.sessionId);
      if (ctx.status !== 'swapped' || ctx.response?.status >= 400) {
        this.setSaveStatus('Saved on this device');
        this.updateSendState();
        showBanner('error', readHtmxErrorMessage(ctx));
      } else {
        this.acknowledgeSubmittedDraft();
        if (document.getElementById('streaming-msg')) {
          this.disableInput();
        } else {
          this.announce('Message queued');
          this.refreshConversationState();
        }
      }
      return;
    }

    const streamContentType = ctx?.response?.headers?.get('content-type') || '';
    if (ctx?.sourceElement?.id === 'streaming-msg' &&
        (!ctx.response || ctx.response.status >= 400 || !streamContentType.includes('text/event-stream'))) {
      const streamUrl = new URL(ctx.request.action, location.href);
      this.streamRecoveryTurnId = streamUrl.searchParams.get('turn');
      ctx.sourceElement.remove();
      this.showRecovery('Live response disconnected. Waiting for the active turn to finish.');
      return;
    }

    const elt = ctx?.sourceElement;
    if (!elt) return;
    const isMessagesReload = elt.id === 'messages';
    const isLoadEarlier = elt.matches && elt.matches('[data-load-earlier]');
    if (!isMessagesReload && !isLoadEarlier) return;
    if (isLoadEarlier) {
      elt.disabled = false;
      this.element.querySelector('[data-load-earlier-skeleton]')?.remove();
    }
    if (ctx.status !== 'swapped' || ctx.response?.status >= 400) {
      if (isLoadEarlier) {
        showBanner('error', readHtmxErrorMessage(ctx));
      }
      this.paginationAnchor = null;
      this.paginationAnchorTop = null;
      return;
    }
    this.updateMessagePagination(ctx);
    if (isLoadEarlier && this.paginationAnchor?.isConnected && this.paginationAnchorTop !== null) {
      const messages = this.element.querySelector('#messages');
      const anchor = this.paginationAnchor;
      const anchorTop = this.paginationAnchorTop;
      requestAnimationFrame(() => {
        if (messages?.isConnected && anchor.isConnected) {
          messages.scrollTop += anchor.getBoundingClientRect().top - anchorTop;
        }
      });
    }
    this.paginationAnchor = null;
    this.paginationAnchorTop = null;
  }

  handleSendButtonClick(event) {
    if (!this.chatRequestPending) return;
    event.preventDefault();
  }

  stopTurn() {
    if (!this.sessionId) return;
    this.sendButton.disabled = true;
    this.announce('Stopping current turn');
    const sessionPath = '/api/sessions/' + encodeURIComponent(this.sessionId);
    fetch(sessionPath + '/turn-status')
      .then((response) => {
        if (!response.ok) throw new Error('Status failed');
        return response.json();
      })
      .then((status) => {
        if (!status.turn_id || status.can_cancel !== true) throw new Error('Turn is not cancellable');
        return fetch(sessionPath + '/turns/' + encodeURIComponent(status.turn_id) + '/cancel', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ reason: 'operator_cancel' }),
        });
      })
      .then((response) => {
        if (!response.ok) throw new Error('Stop failed');
        const deferEnableUntilRefresh = Boolean(this.streamRecoveryTurnId);
        this.showRecovery('Turn stopped. Pending messages are held.');
        this.finalizeTurn({ preserveInput: true, refreshMessages: true, deferEnableUntilRefresh });
      })
      .catch(() => {
        this.sendButton.disabled = false;
        showBanner('error', 'Failed to stop active turn');
      });
  }

  _startTurnStatusPolling() {
    this._stopTurnStatusPolling();
    this.canCancel = false;
    this.updateSendState();
    if (!this.sessionId) return;
    const generation = this.turnStatusPollGeneration;
    const sessionId = this.sessionId;
    let nextRequest = 0;
    let lastAppliedRequest = 0;
    const poll = () => {
      if (!this.streaming || this.turnStatusPollGeneration !== generation || this.sessionId !== sessionId) return;
      const request = ++nextRequest;
      fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/turn-status')
        .then((response) => (response.ok ? response.json() : null))
        .then((status) => {
          if (!this.streaming || this.turnStatusPollGeneration !== generation || this.sessionId !== sessionId) return;
          if (request < lastAppliedRequest) return;
          lastAppliedRequest = request;
          if (this._reconcileStreamRecovery(status)) return;
          const next = Boolean(status && status.can_cancel === true);
          if (next !== this.canCancel) {
            this.canCancel = next;
            this.updateSendState();
          }
        })
        .catch(() => {});
    };
    poll();
    this.turnStatusTimer = setInterval(poll, 2500);
  }

  _reconcileStreamRecovery(status) {
    if (!this.streamRecoveryTurnId || status?.turn_id !== this.streamRecoveryTurnId) return false;
    if (!['completed', 'cancelled', 'failed'].includes(status.state)) return false;
    this.streamRecoveryTurnId = null;
    if (status.state === 'completed') {
      this.hideRecovery();
      this.finalizeTurn({ deferEnableUntilRefresh: true });
    } else {
      const message = status.state === 'cancelled'
        ? 'Turn stopped. Edit your message or send again.'
        : 'Turn failed after live updates disconnected. Edit your message or send again.';
      this.showRecovery(message);
      this.finalizeTurn({ preserveInput: true, deferEnableUntilRefresh: true });
    }
    return true;
  }

  _stopTurnStatusPolling() {
    this.turnStatusPollGeneration += 1;
    if (this.turnStatusTimer !== null) {
      clearInterval(this.turnStatusTimer);
      this.turnStatusTimer = null;
    }
    this.canCancel = false;
  }

  handleLoadEarlierClick(event) {
    const button = event.target.closest('[data-load-earlier]');
    if (!button) return;
    event.preventDefault();
    const earliestCursor = this.element.dataset.earliestCursor;
    if (!this.sessionId || !earliestCursor) return;
    button.disabled = true;
    const messages = document.getElementById('messages');
    this.paginationAnchor = messages?.querySelector('.msg') || null;
    this.paginationAnchorTop = this.paginationAnchor?.getBoundingClientRect().top ?? null;
    const loading = document.createElement('div');
    loading.className = 'skeleton skeleton-text';
    loading.dataset.loadEarlierSkeleton = '1';
    messages?.prepend(loading);
    htmx.ajax('GET', '/sessions/' + encodeURIComponent(this.sessionId) + '/messages-html?before=' + earliestCursor, {
      target: '#messages',
      swap: 'afterbegin',
      source: button,
    });
  }

  updateMessagePagination(ctx) {
    const headers = ctx?.response?.headers;
    if (!headers) return;
    const earliestCursor = headers.get('x-dartclaw-earliest-cursor');
    if (earliestCursor) {
      this.element.dataset.earliestCursor = earliestCursor;
    } else {
      delete this.element.dataset.earliestCursor;
    }
    const button = this.element.querySelector('[data-load-earlier]');
    if (!button) return;
    const hasEarlierMessages = headers.get('x-dartclaw-has-earlier-messages') === 'true';
    button.hidden = !hasEarlierMessages;
    if (hasEarlierMessages) {
      button.removeAttribute('hidden');
    } else {
      button.setAttribute('hidden', 'hidden');
    }
  }

  handleSseBeforeMessage(event) {
    const message = event.detail?.message;
    if (event.target?.id !== 'streaming-msg' || !message) return;
    const stickToBottom = isAtBottom(this.element.querySelector('.messages'));
    event.detail.waitUntil(this.processSseMessage(event.target, message, stickToBottom));
  }

  async processSseMessage(sourceElement, message, stickToBottom) {
    if (message.event === 'delta') {
      document.getElementById('streaming-msg')?.querySelector('.msg-thinking')?.remove();
      document.getElementById('streaming-content')?.classList.add('streaming');
      await htmx.swap({
        text: message.data,
        target: '#streaming-content',
        swap: 'beforeend',
        sourceElement,
      });
    } else if (message.event === 'tool_use') {
      await htmx.swap({
        text: message.data,
        target: '#tool-container',
        swap: 'beforeend',
        sourceElement,
      });
    } else if (message.event === 'tool_result') {
      await htmx.swap({
        text: message.data,
        target: '#tool-container',
        swap: 'none',
        sourceElement,
      });
    } else if (message.event === 'turn_cancelled') {
      this.handleTurnCancelled();
    } else if (message.event === 'turn_error') {
      await htmx.swap({
        text: message.data,
        target: '#turn-error-target',
        swap: 'innerHTML',
        sourceElement,
      });
      this.handleTurnError();
    }
    scrollToBottom(this.element, { stickToBottom });
  }

  handleTurnCancelled() {
    this.showRecovery('Turn stopped. Edit your message or send again.');
  }

  handleSseClose(event) {
    if (event.detail?.reason !== 'message') return;
    this.finalizeTurn({ preserveInput: this.recoveryActive });
  }

  handleTurnError() {
    const container = document.getElementById('turn-error-target');
    const turnError = container && container.querySelector('.turn-error');
    const message = turnError ? turnError.textContent : 'Stream error';
    if (container) container.innerHTML = '';
    this.showRecovery(message + ' Retry by editing and sending again.');
  }

  finalizeTurn(options = {}) {
    if (this.turnFinalized) return;
    this.turnFinalized = true;
    this.streamRecoveryTurnId = null;
    const refreshMessages = options.refreshMessages !== false;
    const deferEnableUntilRefresh = Boolean(options.deferEnableUntilRefresh);
    document.body.classList.remove('streaming');
    document.getElementById('streaming-content')?.classList.remove('streaming');
    const textarea = this.textarea;
    if (!deferEnableUntilRefresh) this.enableInput();
    if (!this.sessionId || !refreshMessages) {
      if (deferEnableUntilRefresh) this.enableInput();
      return;
    }

    const stickToBottom = isAtBottom(this.element.querySelector('.messages'));
    htmx.ajax('GET', '/sessions/' + encodeURIComponent(this.sessionId) + '/messages-html', {
      target: '#messages',
      swap: 'innerHTML',
      source: this.element.querySelector('#messages'),
    })
      .then(() => {
        renderMarkdown(this.element);
        scrollToBottom(this.element, { stickToBottom });
        this.autoTitleSession();
      })
      .catch(() => showToast('error', 'Failed to refresh messages'))
      .finally(() => {
        if (deferEnableUntilRefresh && this.element.isConnected) this.enableInput();
      });
  }

  autoTitleSession() {
    if (this.element.dataset.hasTitle === 'true' || !this.sessionId) return;
    const firstUserMessage = this.element.querySelector('#messages .msg-user .msg-content');
    if (!firstUserMessage) return;
    let title = (firstUserMessage.textContent || '').trim();
    if (title.length > 50) {
      title = title.substring(0, 50).replace(/\s+\S*$/, '');
    }
    if (!title) return;

    fetch('/api/sessions/' + encodeURIComponent(this.sessionId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title }),
    })
      .then((response) => {
        if (!response.ok) return;
        this.element.dataset.hasTitle = 'true';
        const titleInput = document.querySelector('.topbar .session-title[type="text"]');
        if (titleInput) {
          titleInput.value = title;
          titleInput.dataset.originalTitle = title;
        }
        syncSidebarSessionTitle(this.sessionId, title);
      })
      .catch(() => {});
  }

  maybeOpenReferencePalette() {
    const value = this.textarea?.value || '';
    const cursor = this.textarea?.selectionStart || value.length;
    const prefix = value.slice(0, cursor).split(/\s/).pop() || '';
    if (!prefix.startsWith('@')) {
      this.hideReferencePalette();
      return;
    }
    const query = prefix.slice(1);
    this.loadReferences(query);
  }

  loadReferences(query) {
    if (!this.sessionId) return;
    fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/references?q=' + encodeURIComponent(query))
      .then((response) => response.ok ? response.json() : { references: [] })
      .then((payload) => {
        this.filteredReferences = Array.isArray(payload.references) ? payload.references : [];
        this.activeReferenceIndex = 0;
        this.renderReferencePalette();
      })
      .catch(() => {
        this.filteredReferences = [{ type: 'unresolved', id: query, label: query || 'No match', state: 'unresolved' }];
        this.renderReferencePalette();
      });
  }

  renderReferencePalette() {
    const palette = this.referencePalette;
    const list = palette?.querySelector('.composer-palette-list');
    if (!palette || !list) return;
    if (this.filteredReferences.length === 0) {
      list.innerHTML = '<div class="composer-palette-empty">No references found. Keep typing or remove the token.</div>';
      palette.hidden = false;
      return;
    }
    list.innerHTML = this.filteredReferences.map((reference, index) => {
      const selected = index === this.activeReferenceIndex ? ' aria-selected="true"' : '';
      return '<button type="button" role="option" class="composer-palette-option"' + selected +
        ' data-reference-index="' + index + '">' +
        '<span>@' + escapeHtml(reference.label || reference.id || '') + '</span>' +
        '<small>' + escapeHtml(reference.type || 'reference') + '</small>' +
        '</button>';
    }).join('');
    list.querySelectorAll('[data-reference-index]').forEach((button) => {
      button.addEventListener('click', () => this.selectReference(Number(button.dataset.referenceIndex)));
    });
    palette.hidden = false;
  }

  hideReferencePalette() {
    if (this.referencePalette) this.referencePalette.hidden = true;
  }

  handlePaletteKey(event) {
    const items = this.filteredReferences;
    if (event.key === 'Escape') {
      event.preventDefault();
      this.closePalettes();
      return true;
    }
    if (!items.length) return false;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      this.activeReferenceIndex = (this.activeReferenceIndex + delta + items.length) % items.length;
      this.renderReferencePalette();
      return true;
    }
    if (event.key === 'Enter' || event.key === 'Tab') {
      event.preventDefault();
      this.selectReference(this.activeReferenceIndex);
      return true;
    }
    return false;
  }

  selectReference(index) {
    const reference = this.filteredReferences[index];
    if (!reference) return;
    this.references.push({ type: reference.type, id: reference.id, label: reference.label, state: 'resolved' });
    this.replaceCurrentToken('');
    this.hideReferencePalette();
    this.syncRichInputs();
    this.updateSendState();
    this.markDraftChanged();
  }

  replaceCurrentToken(replacement) {
    const textarea = this.textarea;
    if (!textarea) return;
    const value = textarea.value;
    const cursor = textarea.selectionStart || value.length;
    const before = value.slice(0, cursor);
    const after = value.slice(cursor);
    const tokenStart = Math.max(before.lastIndexOf(' ') + 1, before.lastIndexOf('\n') + 1);
    textarea.value = before.slice(0, tokenStart) + replacement + after;
    const nextCursor = tokenStart + replacement.length;
    textarea.setSelectionRange(nextCursor, nextCursor);
    textarea.focus();
  }

  applySuggestion(event) {
    const text = event.currentTarget?.dataset.text;
    if (!text || !this.textarea) return;
    const spacer = this.textarea.value.trim() ? '\n' : '';
    this.textarea.value += spacer + text;
    this.textarea.focus();
    this.updateSendState();
    this.markDraftChanged();
  }

  closePalettes() {
    this.hideReferencePalette();
  }

  handleDragOver(event) {
    event.preventDefault();
  }

  handleDrop(event) {
    event.preventDefault();
    this.addFiles(event.dataTransfer?.files);
  }

  handlePaste(event) {
    this.addFiles(event.clipboardData?.files);
  }

  addFiles(fileList) {
    const files = Array.from(fileList || []);
    files.forEach((file) => this.uploadAttachment(file));
  }

  chooseFiles(event) {
    this.addFiles(event.currentTarget?.files);
    if (event.currentTarget) event.currentTarget.value = '';
  }

  uploadAttachment(file) {
    if (!file || !this.sessionId) return;
    if (this.maxAttachmentBytes > 0 && file.size > this.maxAttachmentBytes) {
      this.showRecovery('Attachment exceeds the server limit. Remove it or choose a smaller file.');
      return;
    }
    const pendingId = 'pending-' + this.generateClientId();
    const pending = {
      id: pendingId,
      filename: file.name,
      mediaType: file.type || 'application/octet-stream',
      size: file.size,
      state: 'uploading',
      file,
    };
    this.attachments.push(pending);
    this.syncRichInputs();
    this.markDraftChanged();
    this.readFileBase64(file)
      .then((contentBase64) => fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/attachments', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          filename: file.name,
          mediaType: file.type || 'application/octet-stream',
          size: file.size,
          contentBase64,
        }),
      }))
      .then((response) => {
        if (!response.ok) throw new Error('Upload failed');
        return response.json();
      })
      .then((attachment) => {
        this.attachments = this.attachments.map((item) => item.id === pendingId ? { ...attachment, file } : item);
        this.syncRichInputs();
        this.markDraftChanged();
      })
      .catch(() => {
        this.attachments = this.attachments.map((item) => item.id === pendingId ? { ...item, state: 'failed' } : item);
        this.syncRichInputs();
        this.markDraftChanged();
      });
  }

  initializeConversationState() {
    if (!this.sessionId) return;
    fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/attachments/limits')
      .then((response) => response.ok ? response.json() : null)
      .then((limits) => {
        if (Number.isInteger(limits?.max_attachment_bytes)) this.maxAttachmentBytes = limits.max_attachment_bytes;
      })
      .catch(() => {});
    this.refreshConversationState();
  }

  handleConversationChanged(event) {
    if (event.detail?.session_id !== this.sessionId) return;
    const revision = Number(event.detail?.revision || 0);
    if (!event.detail?.turn_id && revision <= this.conversationRevision) return;
    this.refreshConversationState();
  }

  refreshConversationState() {
    if (!this.sessionId) return Promise.resolve();
    return fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/conversation-state')
      .then((response) => {
        if (response.status === 401 || response.status === 403) {
          document.body.dispatchEvent(new CustomEvent('dartclaw:authorization-revoked'));
          throw new Error('Conversation access was revoked');
        }
        if (!response.ok) throw new Error('Conversation state unavailable');
        return response.json();
      })
      .then((snapshot) => {
        if (Number(snapshot.revision || 0) < this.conversationRevision) return;
        this.conversationRevision = Number(snapshot.revision || 0);
        this.conversationReady = true;
        this.renderQueue(Array.isArray(snapshot.queue) ? snapshot.queue : []);
        const projectedTurn = snapshot.activity?.turn;
        this.ordinaryControls = snapshot.activity?.ordinary_controls !== false;
        const recovery = (snapshot.submissions || []).find((item) =>
          item.commitState === 'integrityFailed' || item.workState === 'uncertain');
        if (recovery) {
          this.showRecovery(recovery.commitState === 'integrityFailed'
            ? 'Submission integrity could not be recovered. Review the held message before sending again.'
            : 'Dispatch status is uncertain after restart. Review the conversation before sending again.');
        }
        const active = (snapshot.submissions || []).find((item) =>
          ['dispatching', 'running', 'stopping'].includes(item.workState));
        const projectedActive = projectedTurn && ['running', 'waiting', 'stuck', 'cancelling'].includes(projectedTurn.state);
        if (active || projectedActive) {
          this.streaming = true;
          this.canCancel = active ? active.workState !== 'stopping' : Boolean(projectedTurn.can_cancel);
        } else if (!document.getElementById('streaming-msg')) {
          this.streaming = false;
          this.canCancel = false;
        }
        this.updateSendState();
      })
      .catch((error) => {
        this.conversationReady = false;
        this.setSaveStatus(navigator.onLine === false ? 'Offline — draft stays on this device' : 'Conversation unavailable');
        this.showRecovery(error.message);
        this.updateSendState();
      });
  }

  renderQueue(items) {
    const queue = this.queue;
    if (!queue) return;
    const pending = items.filter((item) => ['queued', 'held'].includes(item.workState));
    this.queueItems = new Map(pending.map((item) => [item.queueId, item]));
    queue.hidden = pending.length === 0;
    queue.innerHTML = pending.map((item, index) => {
      const attachments = (item.attachments || []).map((attachment) => escapeHtml(attachment.filename)).join(', ');
      const attachmentLine = attachments ? '<div class="t-caption">Files: ' + attachments + '</div>' : '';
      const release = item.workState === 'held' && index === 0
        ? '<button type="button" class="btn btn-primary" data-action="dc-chat#releaseQueueItem">Send next queued message</button>'
        : '';
      return '<article class="conversation-queue-item" data-queue-id="' + escapeHtml(item.queueId) + '">' +
        '<strong>' + escapeHtml(item.workState === 'held' ? 'Held' : 'Queued') + '</strong>' +
        '<p>' + escapeHtml(item.message) + '</p>' + attachmentLine +
        '<div class="conversation-queue-actions">' +
        '<button type="button" class="btn btn-ghost" data-action="dc-chat#editQueueItem">Edit</button>' +
        '<button type="button" class="btn btn-ghost" data-action="dc-chat#removeQueueItem">Remove</button>' + release +
        '</div></article>';
    }).join('');
  }

  queueMutation(path, options) {
    return fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + path, options)
      .then(async (response) => {
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload?.error?.message || payload?.message || 'Queue changed in another view');
        await this.refreshConversationState();
        return payload;
      })
      .catch((error) => {
        this.showRecovery(error.message);
        return this.refreshConversationState();
      });
  }

  editQueueItem(event) {
    const item = event.currentTarget?.closest('[data-queue-id]');
    const message = item?.querySelector('p')?.textContent || '';
    const replacement = window.prompt('Edit queued message', message);
    if (replacement === null || !replacement.trim()) return;
    const queueId = item.dataset.queueId;
    const queued = this.queueItems.get(queueId);
    this.queueMutation('/queue/' + encodeURIComponent(queueId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        conversation_revision: this.conversationRevision,
        revision_id: this.generateClientId(),
        message: replacement.trim(),
        attachments: queued?.attachments || [],
        references: queued?.references || [],
      }),
    });
  }

  removeQueueItem(event) {
    const queueId = event.currentTarget?.closest('[data-queue-id]')?.dataset.queueId;
    if (!queueId) return;
    this.queueMutation('/queue/' + encodeURIComponent(queueId), {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ conversation_revision: this.conversationRevision }),
    });
  }

  releaseQueueItem() {
    this.queueMutation('/queue/release', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ conversation_revision: this.conversationRevision }),
    });
  }

  steer() {
    if (!this.canSubmitRichInput() || !this.textarea?.value.trim() || !this.canCancel) return;
    const draft = this.currentDraft();
    this.chatRequestPending = true;
    this.submittedRevisionId = draft.revisionId;
    this.submittedDraft = draft;
    this.announce('Stopping current turn before sending follow-up');
    this.updateSendState();
    fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/steer', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        submission_id: draft.submissionId,
        revision_id: draft.revisionId,
        message: draft.text.trim(),
        attachments: draft.attachments.filter((item) => item.state === 'ready'),
        references: draft.references,
      }),
    })
      .then(async (response) => {
        if (!response.ok) throw new Error((await response.json().catch(() => null))?.error?.message || 'Steer failed');
        this.acknowledgeSubmittedDraft();
        this.disableInput();
        this.announce('Follow-up accepted after the current turn stopped');
      })
      .catch((error) => this.showRecovery(error.message))
      .finally(() => {
        this.chatRequestPending = false;
        this.updateSendState();
        this.refreshConversationState();
      });
  }

  handleConnectivityChange() {
    if (navigator.onLine === false) {
      this.setSaveStatus('Offline — draft stays on this device');
      this.announce('Disconnected. Drafting remains available.');
      this.updateSendState();
      return;
    }
    this.announce('Reconnected. Review your draft before sending.');
    this.saveDraftNow();
    this.refreshConversationState();
  }

  currentDraft() {
    return {
      key: this.draftKey,
      submissionId: this.draftSubmissionId || (this.draftSubmissionId = this.generateClientId()),
      revisionId: this.draftRevisionId,
      text: this.textarea?.value || '',
      references: this.references.map((item) => ({ ...item })),
      attachments: this.attachments.map((item) => ({ ...item })),
      updatedAt: Date.now(),
    };
  }

  markDraftChanged() {
    this.draftTouched = true;
    this.draftRevisionId = this.generateClientId();
    this.draftSubmissionId = this.generateClientId();
    this.scheduleDraftSave();
  }

  scheduleDraftSave() {
    clearTimeout(this.saveTimer);
    this.setSaveStatus('Saving…');
    this.saveTimer = setTimeout(() => this.saveDraftNow(), 150);
  }

  initializeDraftStorage() {
    let instanceId;
    try {
      instanceId = localStorage.getItem('dartclaw.instance-id');
      if (!instanceId) {
        instanceId = this.generateClientId();
        localStorage.setItem('dartclaw.instance-id', instanceId);
      }
    } catch (_) {
      instanceId = 'local';
    }
    this.provisionalDraftKey = instanceId + ':provisional';
    this.draftKey = instanceId + ':' + (this.sessionId || 'provisional');
    if (typeof BroadcastChannel === 'function') {
      this.draftChannel = new BroadcastChannel('dartclaw-drafts');
      this.draftChannel.onmessage = (event) => this.receiveDraftUpdate(event.data);
    }
    this.openDraftDb()
      .then((db) => {
        this.draftDb = db;
        return this.readStoredDraft();
      })
      .then((draft) => {
        if (draft) this.applyStoredDraft(draft);
        this.setSaveStatus(draft ? 'Saved on this device' : 'No saved draft');
        this.updateSendState();
      })
      .catch(() => this.showDraftSaveFailure());
  }

  openDraftDb() {
    if (!globalThis.indexedDB) return Promise.reject(new Error('IndexedDB unavailable'));
    return new Promise((resolve, reject) => {
      const request = indexedDB.open('dartclaw-conversation-drafts', 1);
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains('drafts')) request.result.createObjectStore('drafts', { keyPath: 'key' });
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  draftRequest(mode, operation) {
    if (!this.draftDb) return Promise.reject(new Error('Draft storage unavailable'));
    return new Promise((resolve, reject) => {
      const transaction = this.draftDb.transaction('drafts', mode);
      const request = operation(transaction.objectStore('drafts'));
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      transaction.onabort = () => reject(transaction.error);
    });
  }

  readStoredDraft() {
    return this.draftRequest('readonly', (store) => store.get(this.draftKey))
      .then((draft) => draft || this.transferProvisionalDraft());
  }

  transferProvisionalDraft() {
    if (!this.sessionId || this.draftKey === this.provisionalDraftKey || !this.draftDb) return Promise.resolve(null);
    return new Promise((resolve, reject) => {
      const transaction = this.draftDb.transaction('drafts', 'readwrite');
      const store = transaction.objectStore('drafts');
      const request = store.get(this.provisionalDraftKey);
      let transferred = null;
      request.onsuccess = () => {
        if (!request.result) return;
        transferred = { ...request.result, key: this.draftKey };
        store.put(transferred);
        store.delete(this.provisionalDraftKey);
      };
      request.onerror = () => reject(request.error);
      transaction.oncomplete = () => resolve(transferred);
      transaction.onabort = () => reject(transaction.error);
    });
  }

  saveDraftNow() {
    clearTimeout(this.saveTimer);
    const draft = this.currentDraft();
    return this.draftRequest('readwrite', (store) => store.put(draft))
      .then(() => {
        this.setSaveStatus('Saved on this device');
        this.hideDraftRecoveryActions();
        this.draftChannel?.postMessage({ key: draft.key, revisionId: draft.revisionId, updatedAt: draft.updatedAt });
      })
      .catch(() => this.showDraftSaveFailure());
  }

  showDraftSaveFailure() {
    this.setSaveStatus('Unsaved — this draft will not recover after reload');
    this.showRecovery('Could not save this draft on this device. Keep editing, retry, copy, or download it.');
    if (this.recoveryActions) this.recoveryActions.hidden = false;
  }

  hideDraftRecoveryActions() {
    if (!this.recoveryActions || this.pendingConflict) return;
    this.recoveryActions.hidden = true;
  }

  receiveDraftUpdate(update) {
    if (!update || update.key !== this.draftKey || update.revisionId === this.draftRevisionId) return;
    this.readStoredDraft().then((draft) => {
      if (!draft) return;
      if (this.draftTouched) {
        this.pendingConflict = draft;
        this.showRecovery('Another tab saved a different revision. Recover it or keep your current draft.');
        if (this.recoveryActions) this.recoveryActions.hidden = false;
        if (this.conflictAction) this.conflictAction.hidden = false;
      } else {
        this.applyStoredDraft(draft);
      }
    }).catch(() => {});
  }

  recoverConflictingDraft() {
    if (!this.pendingConflict) return;
    this.applyStoredDraft(this.pendingConflict);
    this.pendingConflict = null;
    if (this.conflictAction) this.conflictAction.hidden = true;
    this.hideRecovery();
    this.hideDraftRecoveryActions();
  }

  applyStoredDraft(draft) {
    if (this.textarea) this.textarea.value = draft.text || '';
    this.references = Array.isArray(draft.references) ? draft.references : [];
    this.attachments = Array.isArray(draft.attachments) ? draft.attachments : [];
    this.draftRevisionId = draft.revisionId || this.generateClientId();
    this.draftSubmissionId = draft.submissionId || this.generateClientId();
    this.draftTouched = false;
    const localAttachments = this.sessionId
      ? this.attachments.filter((attachment) => attachment.state === 'local' && attachment.file)
      : [];
    if (localAttachments.length > 0) {
      this.attachments = this.attachments.filter((attachment) => !localAttachments.includes(attachment));
      localAttachments.forEach((attachment) => this.uploadAttachment(attachment.file));
    }
    this.syncRichInputs();
  }

  acknowledgeSubmittedDraft() {
    if (!this.submittedDraft) return;
    if (this.draftRevisionId === this.submittedRevisionId) {
      if (this.textarea) this.textarea.value = '';
      this.attachments = [];
      this.references = [];
      this.syncRichInputs();
      this.draftRevisionId = this.generateClientId();
      this.draftSubmissionId = this.generateClientId();
      this.draftTouched = false;
      this.saveDraftNow();
    } else {
      this.saveDraftNow();
    }
    this.submittedDraft = null;
    this.submittedRevisionId = null;
    this.setSaveStatus('Saved on this device');
  }

  copyDraft() {
    const text = this.textarea?.value || '';
    if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text);
  }

  downloadDraft() {
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([this.textarea?.value || ''], { type: 'text/plain' }));
    link.download = 'dartclaw-draft.txt';
    link.click();
    URL.revokeObjectURL(link.href);
  }

  setSaveStatus(message) {
    if (this.saveStatus) this.saveStatus.textContent = message;
  }

  announce(message) {
    if (this.liveStatus) this.liveStatus.textContent = message;
  }

  generateClientId() {
    if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') {
      return globalThis.crypto.randomUUID();
    }
    return Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
  }

  readFileBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const result = String(reader.result || '');
        resolve(result.includes(',') ? result.split(',').pop() : result);
      };
      reader.onerror = () => reject(reader.error || new Error('File read failed'));
      reader.readAsDataURL(file);
    });
  }

  removeAttachment(event) {
    const id = event.currentTarget?.dataset.attachmentId;
    const attachment = this.attachments.find((item) => item.id === id);
    this.attachments = this.attachments.filter((item) => item.id !== id);
    if (attachment && !String(id).startsWith('pending-') && this.sessionId) {
      fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/attachments/' + encodeURIComponent(id), { method: 'DELETE' }).catch(() => {});
    }
    this.syncRichInputs();
    this.updateSendState();
    this.markDraftChanged();
  }

  removeReference(event) {
    const id = event.currentTarget?.dataset.referenceId;
    this.references = this.references.filter((reference) => reference.id !== id);
    this.syncRichInputs();
    this.updateSendState();
    this.markDraftChanged();
  }

  retryAttachment(event) {
    const id = event.currentTarget?.dataset.attachmentId;
    const attachment = this.attachments.find((item) => item.id === id);
    if (!attachment?.file) return;
    this.attachments = this.attachments.filter((item) => item.id !== id);
    this.syncRichInputs();
    this.uploadAttachment(attachment.file);
  }

  syncRichInputs() {
    if (this.attachmentsInput) {
      this.attachmentsInput.value = JSON.stringify(this.attachments.filter((attachment) => attachment.state === 'ready'));
    }
    if (this.referencesInput) {
      this.referencesInput.value = JSON.stringify(this.references.filter((reference) => reference.state === 'resolved'));
    }
    const tray = this.contextTray;
    if (!tray) return;
    const chips = [
      ...this.attachments.map((attachment) => this.renderAttachmentChip(attachment)),
      ...this.references.map((reference) => this.renderReferenceChip(reference)),
    ];
    tray.innerHTML = chips.join('');
    tray.hidden = chips.length === 0;
  }

  renderAttachmentChip(attachment) {
    const failed = attachment.state === 'failed';
    const id = escapeHtml(attachment.id);
    const retry = failed
      ? '<button type="button" class="chip" data-action="dc-chat#retryAttachment" data-attachment-id="' + id + '"><span class="chip-name">Retry upload</span></button>'
      : '';
    return '<span class="chip">' +
      '<span class="chip-name">' + escapeHtml(attachment.filename) + '</span>' +
      '<span class="chip-meta">' + escapeHtml(attachment.state || 'ready') + '</span>' +
      '<button type="button" class="chip-remove" aria-label="Remove attachment" data-action="dc-chat#removeAttachment" data-attachment-id="' + id + '"></button>' +
      '</span>' + retry;
  }

  renderReferenceChip(reference) {
    return '<span class="chip chip--ref">' +
      '<span class="chip-name">@' + escapeHtml(reference.label) + '</span>' +
      '<span class="chip-meta">' + escapeHtml(reference.type) + '</span>' +
      '<button type="button" class="chip-remove" aria-label="Remove reference" data-action="dc-chat#removeReference" data-reference-id="' + escapeHtml(reference.id) + '"></button>' +
      '</span>';
  }

  canSubmitRichInput() {
    if (this.attachments.some((attachment) => attachment.state === 'uploading')) {
      this.showRecovery('Attachment upload is still running. Wait, retry, or remove it.');
      return false;
    }
    if (this.attachments.some((attachment) => attachment.state === 'failed')) {
      this.showRecovery('Attachment upload failed. Retry or remove the failed chip.');
      return false;
    }
    const unresolved = (this.textarea?.value || '').match(/(^|\s)@[\w./:-]+/);
    if (unresolved) {
      this.showRecovery('Resolve or remove the reference token before sending.');
      return false;
    }
    return true;
  }

  showRecovery(message) {
    const recovery = this.recovery;
    if (!recovery) return;
    this.recoveryActive = true;
    recovery.textContent = message;
    recovery.hidden = false;
  }

  hideRecovery() {
    const recovery = this.recovery;
    if (!recovery) return;
    this.recoveryActive = false;
    recovery.hidden = true;
    recovery.textContent = '';
  }
}
