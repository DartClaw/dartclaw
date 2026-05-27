import { readHtmxErrorMessage, renderMarkdown, scrollToBottom, showBanner, showToast } from './shared.js';

export default class DcChatController extends Stimulus.Controller {
  connect() {
    this.handleBeforeRequest = this.handleBeforeRequest.bind(this);
    this.handleAfterRequest = this.handleAfterRequest.bind(this);
    this.handleSseMessage = this.handleSseMessage.bind(this);
    this.handleSseClose = this.handleSseClose.bind(this);
    this.handleLoadEarlierClick = this.handleLoadEarlierClick.bind(this);
    this.handleTextareaInput = this.handleTextareaInput.bind(this);
    this.handleTextareaKeydown = this.handleTextareaKeydown.bind(this);

    document.body.addEventListener('htmx:beforeRequest', this.handleBeforeRequest);
    document.body.addEventListener('htmx:afterRequest', this.handleAfterRequest);
    document.body.addEventListener('htmx:sseMessage', this.handleSseMessage);
    document.body.addEventListener('htmx:sseClose', this.handleSseClose);
    this.element.addEventListener('click', this.handleLoadEarlierClick);

    this.initTextarea();
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
    const textarea = this.textarea;
    if (textarea) {
      textarea.removeEventListener('input', this.handleTextareaInput);
      textarea.removeEventListener('keydown', this.handleTextareaKeydown);
    }
  }

  get textarea() {
    return this.element.querySelector('#message-input');
  }

  get sendButton() {
    return this.element.querySelector('#send-btn');
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
    this.updateSendState();
  }

  handleTextareaKeydown(event) {
    if (!(event.ctrlKey || event.metaKey) || event.key !== 'Enter') return;
    event.preventDefault();
    this.element.querySelector('#chat-form')?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  }

  updateSendState() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (button) {
      button.disabled = !textarea || !textarea.value.trim();
    }
  }

  disableInput() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (textarea) {
      textarea.disabled = true;
      textarea.placeholder = 'Agent is responding...';
    }
    if (button) {
      button.disabled = true;
    }
  }

  enableInput() {
    const textarea = this.textarea;
    const button = this.sendButton;
    if (textarea) {
      textarea.disabled = false;
      textarea.placeholder = 'Type a message...';
    }
    if (button) {
      button.disabled = !textarea || !textarea.value.trim();
    }
  }

  isChatFormRequest(event) {
    return event.detail && event.detail.elt && event.detail.elt.id === 'chat-form';
  }

  handleBeforeRequest(event) {
    if (this.isChatFormRequest(event)) {
      this.disableInput();
    }
  }

  handleAfterRequest(event) {
    if (this.isChatFormRequest(event)) {
      if (!event.detail.successful) {
        this.enableInput();
        showBanner('error', readHtmxErrorMessage(event.detail.xhr));
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
    this.finalizeTurn();
  }

  handleTurnError() {
    const container = document.getElementById('turn-error-target');
    const turnError = container && container.querySelector('.turn-error');
    const message = turnError ? turnError.textContent : 'Stream error';
    if (container) container.innerHTML = '';
    this.finalizeTurn();
    showBanner('error', message);
  }

  finalizeTurn() {
    document.body.classList.remove('streaming');
    document.getElementById('streaming-content')?.classList.remove('streaming');
    const textarea = this.textarea;
    if (textarea) {
      textarea.value = '';
      textarea.style.height = 'auto';
    }
    this.enableInput();
    if (!this.sessionId) return;

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
}
