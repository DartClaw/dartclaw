import { escapeHtml, readHtmxErrorMessage, renderMarkdown, scrollToBottom, showBanner, showToast } from './shared.js';

export default class DcChatController extends Stimulus.Controller {
  connect() {
    this.attachments = [];
    this.references = [];
    this.commands = [];
    this.filteredCommands = [];
    this.filteredReferences = [];
    this.activeCommandIndex = 0;
    this.activeReferenceIndex = 0;
    this.streaming = false;
    this.recoveryActive = false;
    this.canCancel = false;
    this.turnStatusTimer = null;
    this.handleBeforeRequest = this.handleBeforeRequest.bind(this);
    this.handleAfterRequest = this.handleAfterRequest.bind(this);
    this.handleSseMessage = this.handleSseMessage.bind(this);
    this.handleSseClose = this.handleSseClose.bind(this);
    this.handleLoadEarlierClick = this.handleLoadEarlierClick.bind(this);
    this.handleTextareaInput = this.handleTextareaInput.bind(this);
    this.handleTextareaKeydown = this.handleTextareaKeydown.bind(this);
    this.handleSendButtonClick = this.handleSendButtonClick.bind(this);

    document.body.addEventListener('htmx:beforeRequest', this.handleBeforeRequest);
    document.body.addEventListener('htmx:afterRequest', this.handleAfterRequest);
    document.body.addEventListener('htmx:sseMessage', this.handleSseMessage);
    document.body.addEventListener('htmx:sseClose', this.handleSseClose);
    this.element.addEventListener('click', this.handleLoadEarlierClick);

    this.initTextarea();
    this.sendButton?.addEventListener('click', this.handleSendButtonClick);
    this.loadCommands();
    this.updateSendState();
    renderMarkdown(this.element);
    scrollToBottom(this.element);
  }

  disconnect() {
    document.body.removeEventListener('htmx:beforeRequest', this.handleBeforeRequest);
    document.body.removeEventListener('htmx:afterRequest', this.handleAfterRequest);
    document.body.removeEventListener('htmx:sseMessage', this.handleSseMessage);
    document.body.removeEventListener('htmx:sseClose', this.handleSseClose);
    this.element.removeEventListener('click', this.handleLoadEarlierClick);
    this._stopTurnStatusPolling();
    const textarea = this.textarea;
    if (textarea) {
      textarea.removeEventListener('input', this.handleTextareaInput);
      textarea.removeEventListener('keydown', this.handleTextareaKeydown);
    }
    this.sendButton?.removeEventListener('click', this.handleSendButtonClick);
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

  get commandPalette() {
    return this.element.querySelector('[data-dc-chat-target="commandPalette"]');
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
    textarea.style.height = textarea.scrollHeight + 'px';
    this.hideRecovery();
    this.maybeOpenCommandPalette();
    this.maybeOpenReferencePalette();
    this.updateSendState();
  }

  handleTextareaKeydown(event) {
    if (this.commandPalette && !this.commandPalette.hidden && this.handlePaletteKey(event, 'command')) return;
    if (this.referencePalette && !this.referencePalette.hidden && this.handlePaletteKey(event, 'reference')) return;
    if (!(event.ctrlKey || event.metaKey) || event.key !== 'Enter') return;
    event.preventDefault();
    this.form?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  }

  updateSendState() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (button) {
      if (this.streaming) {
        // Only enable Stop once the authoritative turn-status snapshot reports
        // the turn is cancellable. A plain `running` turn returns
        // can_cancel: false, so Stop stays disabled until the poll observes it
        // become cancellable (waiting/stuck) — avoiding a Stop control that
        // looks active but always fails.
        button.disabled = !this.canCancel;
        button.type = 'button';
        button.textContent = 'Stop';
        button.classList.add('btn-stop');
      } else {
        button.disabled = !textarea || (!textarea.value.trim() && this.attachments.length === 0 && this.references.length === 0);
        button.type = 'submit';
        button.textContent = 'Send';
        button.classList.remove('btn-stop');
      }
    }
  }

  disableInput() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (textarea) {
      textarea.disabled = true;
      textarea.placeholder = 'Agent is responding...';
    }
    this.streaming = true;
    document.body.classList.add('streaming');
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
    this._stopTurnStatusPolling();
    if (button) button.disabled = !textarea || !textarea.value.trim();
    this.updateSendState();
  }

  isChatFormRequest(event) {
    return event.detail && event.detail.elt && event.detail.elt.id === 'chat-form';
  }

  handleBeforeRequest(event) {
    if (this.isChatFormRequest(event)) {
      if (!this.canSubmitRichInput()) {
        event.preventDefault();
        return;
      }
      this.hideRecovery();
      this.disableInput();
    }
  }

  handleAfterRequest(event) {
    if (this.isChatFormRequest(event)) {
      if (!event.detail.successful) {
        this.enableInput();
        showBanner('error', readHtmxErrorMessage(event.detail.xhr));
      } else if (!document.getElementById('streaming-msg')) {
        this.finalizeTurn({ refreshMessages: false });
      }
      return;
    }

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
        showBanner('error', readHtmxErrorMessage(event.detail.xhr));
      }
      return;
    }
    this.updateMessagePagination(event.detail.xhr);
  }

  handleSendButtonClick(event) {
    if (!this.streaming) return;
    event.preventDefault();
    this.stopTurn();
  }

  stopTurn() {
    if (!this.sessionId) return;
    this.sendButton.disabled = true;
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
        this.showRecovery('Turn stopped. Edit your message or send again.');
        this.finalizeTurn({ preserveInput: true, refreshMessages: true });
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
    const poll = () => {
      if (!this.streaming || !this.sessionId) return;
      fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/turn-status')
        .then((response) => (response.ok ? response.json() : null))
        .then((status) => {
          if (!this.streaming) return;
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

  _stopTurnStatusPolling() {
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
    htmx.ajax('GET', '/sessions/' + encodeURIComponent(this.sessionId) + '/messages-html?before=' + earliestCursor, {
      target: '#messages',
      swap: 'afterbegin',
      source: button,
    });
  }

  updateMessagePagination(xhr) {
    if (!xhr) return;
    const earliestCursor = xhr.getResponseHeader('x-dartclaw-earliest-cursor');
    if (earliestCursor) {
      this.element.dataset.earliestCursor = earliestCursor;
    } else {
      delete this.element.dataset.earliestCursor;
    }
    const button = this.element.querySelector('[data-load-earlier]');
    if (!button) return;
    const hasEarlierMessages = xhr.getResponseHeader('x-dartclaw-has-earlier-messages') === 'true';
    button.hidden = !hasEarlierMessages;
    if (hasEarlierMessages) {
      button.removeAttribute('hidden');
    } else {
      button.setAttribute('hidden', 'hidden');
    }
  }

  handleSseMessage() {
    scrollToBottom(this.element);
  }

  handleSseClose() {
    this.finalizeTurn({ preserveInput: this.recoveryActive });
  }

  handleTurnError() {
    const container = document.getElementById('turn-error-target');
    const turnError = container && container.querySelector('.turn-error');
    const message = turnError ? turnError.textContent : 'Stream error';
    if (container) container.innerHTML = '';
    this.showRecovery(message + ' Retry by editing and sending again.');
    this.finalizeTurn({ preserveInput: true, refreshMessages: true });
  }

  finalizeTurn(options = {}) {
    const preserveInput = Boolean(options.preserveInput);
    const refreshMessages = options.refreshMessages !== false;
    document.body.classList.remove('streaming');
    document.getElementById('streaming-content')?.classList.remove('streaming');
    const textarea = this.textarea;
    if (textarea && !preserveInput) {
      textarea.value = '';
      textarea.style.height = 'auto';
    }
    if (!preserveInput) {
      this.attachments = [];
      this.references = [];
      this.syncRichInputs();
    }
    this.enableInput();
    if (!this.sessionId || !refreshMessages) return;

    htmx.ajax('GET', '/sessions/' + encodeURIComponent(this.sessionId) + '/messages-html', {
      target: '#messages',
      swap: 'innerHTML',
      source: this.element.querySelector('#messages'),
    })
      .then(() => {
        renderMarkdown(this.element);
        scrollToBottom(this.element);
        this.autoTitleSession();
      })
      .catch(() => showToast('error', 'Failed to refresh messages'));
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
        const sidebarItem = document.querySelector('.session-item.active .session-item-title');
        if (sidebarItem) sidebarItem.textContent = title;
      })
      .catch(() => {});
  }

  loadCommands() {
    if (!this.sessionId) return;
    fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/commands')
      .then((response) => response.ok ? response.json() : { commands: [] })
      .then((payload) => {
        this.commands = Array.isArray(payload.commands) ? payload.commands : [];
      })
      .catch(() => {
        this.commands = [];
      });
  }

  openCommandPalette() {
    this.filteredCommands = this.commands;
    this.activeCommandIndex = 0;
    this.renderCommandPalette();
  }

  maybeOpenCommandPalette() {
    const value = this.textarea?.value || '';
    const cursor = this.textarea?.selectionStart || value.length;
    const prefix = value.slice(0, cursor).split(/\s/).pop() || '';
    if (!prefix.startsWith('/')) {
      this.hideCommandPalette();
      return;
    }
    const query = prefix.slice(1).toLowerCase();
    this.filteredCommands = this.commands.filter((command) => {
      const label = String(command.label || '').toLowerCase();
      return label.includes(query);
    });
    this.activeCommandIndex = 0;
    this.renderCommandPalette();
  }

  renderCommandPalette() {
    const palette = this.commandPalette;
    const list = palette?.querySelector('.composer-palette-list');
    if (!palette || !list) return;
    if (this.filteredCommands.length === 0) {
      palette.hidden = true;
      return;
    }
    list.innerHTML = this.filteredCommands.map((command, index) => {
      const selected = index === this.activeCommandIndex ? ' aria-selected="true"' : '';
      return '<button type="button" role="option" class="composer-palette-option"' + selected +
        ' data-command-index="' + index + '">' +
        '<span>' + escapeHtml(command.label || '') + '</span>' +
        '<small>' + escapeHtml(command.description || '') + '</small>' +
        '</button>';
    }).join('');
    list.querySelectorAll('[data-command-index]').forEach((button) => {
      button.addEventListener('click', () => this.selectCommand(Number(button.dataset.commandIndex)));
    });
    palette.hidden = false;
  }

  hideCommandPalette() {
    if (this.commandPalette) this.commandPalette.hidden = true;
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

  handlePaletteKey(event, paletteType) {
    const items = paletteType === 'command' ? this.filteredCommands : this.filteredReferences;
    if (event.key === 'Escape') {
      event.preventDefault();
      this.closePalettes();
      return true;
    }
    if (!items.length) return false;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      if (paletteType === 'command') {
        this.activeCommandIndex = (this.activeCommandIndex + delta + items.length) % items.length;
        this.renderCommandPalette();
      } else {
        this.activeReferenceIndex = (this.activeReferenceIndex + delta + items.length) % items.length;
        this.renderReferencePalette();
      }
      return true;
    }
    if (event.key === 'Enter' || event.key === 'Tab') {
      event.preventDefault();
      paletteType === 'command' ? this.selectCommand(this.activeCommandIndex) : this.selectReference(this.activeReferenceIndex);
      return true;
    }
    return false;
  }

  selectCommand(index) {
    const command = this.filteredCommands[index];
    if (!command) return;
    this.replaceCurrentToken(command.insertText || command.label || '');
    this.hideCommandPalette();
    this.updateSendState();
  }

  selectReference(index) {
    const reference = this.filteredReferences[index];
    if (!reference) return;
    this.references.push({ type: reference.type, id: reference.id, label: reference.label, state: 'resolved' });
    this.replaceCurrentToken('');
    this.hideReferencePalette();
    this.syncRichInputs();
    this.updateSendState();
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
  }

  closePalettes() {
    this.hideCommandPalette();
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

  uploadAttachment(file) {
    if (!file || !this.sessionId) return;
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
        this.attachments = this.attachments.map((item) => item.id === pendingId ? attachment : item);
        this.syncRichInputs();
      })
      .catch(() => {
        this.attachments = this.attachments.map((item) => item.id === pendingId ? { ...item, state: 'failed' } : item);
        this.syncRichInputs();
      });
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
    this.attachments = this.attachments.filter((attachment) => attachment.id !== id);
    this.syncRichInputs();
    this.updateSendState();
  }

  removeReference(event) {
    const id = event.currentTarget?.dataset.referenceId;
    this.references = this.references.filter((reference) => reference.id !== id);
    this.syncRichInputs();
    this.updateSendState();
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
    return '<span class="composer-chip composer-chip-attachment' + (failed ? ' is-error' : '') + '">' +
      '<span>' + escapeHtml(attachment.filename) + '</span>' +
      '<small>' + escapeHtml(attachment.state || 'ready') + '</small>' +
      (failed ? '<button type="button" data-action="dc-chat#retryAttachment" data-attachment-id="' + escapeHtml(attachment.id) + '">Retry</button>' : '') +
      '<button type="button" aria-label="Remove attachment" data-action="dc-chat#removeAttachment" data-attachment-id="' + escapeHtml(attachment.id) + '">x</button>' +
      '</span>';
  }

  renderReferenceChip(reference) {
    return '<span class="composer-chip composer-chip-reference">' +
      '<span>@' + escapeHtml(reference.label) + '</span>' +
      '<small>' + escapeHtml(reference.type) + '</small>' +
      '<button type="button" aria-label="Remove reference" data-action="dc-chat#removeReference" data-reference-id="' + escapeHtml(reference.id) + '">x</button>' +
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
