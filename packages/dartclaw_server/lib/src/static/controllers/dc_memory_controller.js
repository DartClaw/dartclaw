export default class DcMemoryController extends Stimulus.Controller {
  connect() {
    this.afterSwapHandler = (event) => this.afterSwap(event);
    this.element.addEventListener('htmx:afterSwap', this.afterSwapHandler);
    this.initializeView();
  }

  disconnect() {
    if (this.afterSwapHandler) {
      this.element.removeEventListener('htmx:afterSwap', this.afterSwapHandler);
      this.afterSwapHandler = null;
    }
  }

  get apiQs() {
    return window.dartclaw?.shell?.apiQs?.() || '';
  }

  afterSwap(event) {
    const target = event?.detail?.target;
    if (target?.id === 'memory-content' || target?.id === 'memory-inner') {
      this.initializeView();
    }
  }

  initializeView() {
    this.initMemoryViewToggle();
    this.initMemoryDefaultTab();
  }

  initMemoryViewToggle() {
    if (localStorage.getItem('dartclaw-memory-view') !== 'rendered') return;

    this.element.querySelectorAll('.toggle-btn[data-mode="rendered"]').forEach((button) => {
      button.classList.add('active');
      if (button.previousElementSibling) {
        button.previousElementSibling.classList.remove('active');
      }
    });
  }

  initMemoryDefaultTab() {
    const activeTab = this.element.querySelector('.tab.active[data-action="click->dc-memory#switchTab"][data-tab]');
    if (!activeTab) return;

    const tabId = activeTab.dataset.tab;
    const panel = document.getElementById(tabId);
    if (!panel) return;

    const preview = panel.querySelector('.memory-preview');
    if (preview && !preview.dataset.loaded && !preview.dataset.loading) {
      this.loadPreview(preview);
    }
  }

  switchTab(event) {
    const button = event?.currentTarget;
    const tabId = button?.dataset?.tab;
    if (!button || !tabId) return;

    const card = button.closest('.card');
    if (!card) return;

    card.querySelectorAll('.tab').forEach((tab) => {
      tab.classList.remove('active');
      tab.setAttribute('aria-selected', 'false');
    });
    button.classList.add('active');
    button.setAttribute('aria-selected', 'true');

    card.querySelectorAll('.tab-panel').forEach((panel) => panel.classList.remove('active'));
    const panel = card.querySelector('#' + CSS.escape(tabId));
    if (panel) panel.classList.add('active');

    const preview = panel?.querySelector('.memory-preview');
    if (preview && !preview.dataset.loaded && !preview.dataset.loading) {
      this.loadPreview(preview);
    }
  }

  toggleView(event) {
    const button = event?.currentTarget;
    const mode = button?.dataset?.mode;
    if (!button || !mode) return;

    const group = button.closest('.toggle-btn-group');
    if (group) {
      group.querySelectorAll('.toggle-btn').forEach((toggleButton) => toggleButton.classList.remove('active'));
    }
    button.classList.add('active');
    localStorage.setItem('dartclaw-memory-view', mode);
    this.element.querySelectorAll('.memory-preview[data-loaded]').forEach((preview) => this.applyMemoryViewMode(preview));
  }

  // Prune states swap the button's variant class rather than painting its text
  // colour, so each state keeps real button chrome and stays legible to a
  // reader who cannot separate the colours.
  setPruneState(button, label, variant, disabled = false) {
    button.textContent = label;
    button.classList.remove('btn-danger', 'btn-danger-fill', 'btn-ghost');
    button.classList.add(variant);
    button.disabled = disabled;
  }

  confirmPrune(event) {
    const button = event?.currentTarget;
    if (!button) return;

    if (button.dataset.confirming) {
      delete button.dataset.confirming;
      this.setPruneState(button, 'Pruning...', 'btn-danger-fill', true);
      this.pruneMemory(button);
      return;
    }

    button.dataset.confirming = '1';
    this.setPruneState(button, 'Confirm Prune?', 'btn-danger-fill');
    window.setTimeout(() => {
      if (button.dataset.confirming) {
        delete button.dataset.confirming;
        this.resetPruneButton(button);
      }
    }, 4000);
  }

  async loadPreview(preview) {
    const fileName = preview.dataset.file;
    if (!fileName) return;

    preview.dataset.loading = '1';
    preview.innerHTML = '<div class="skeleton skeleton-text"></div>';
    try {
      const response = await fetch('/api/memory/files/' + encodeURIComponent(fileName) + this.apiQs);
      if (!response.ok) throw new Error('Memory file request failed');

      preview.dataset.rawContent = await response.text();
      preview.dataset.loaded = '1';
      delete preview.dataset.loading;
      this.applyMemoryViewMode(preview);
    } catch (_) {
      delete preview.dataset.loading;
      preview.textContent = 'Failed to load file content.';
    }
  }

  applyMemoryViewMode(preview) {
    const rawContent = preview.dataset.rawContent;
    if (rawContent == null) return;

    if (rawContent === '') {
      preview.textContent = 'File is empty - no entries yet.';
      return;
    }

    const mode = localStorage.getItem('dartclaw-memory-view') || 'raw';
    if (mode === 'rendered' && window.marked && window.DOMPurify) {
      preview.innerHTML = window.DOMPurify.sanitize(window.marked.parse(rawContent));
    } else {
      preview.textContent = rawContent;
    }
  }

  async pruneMemory(button) {
    try {
      const response = await fetch('/api/memory/prune' + this.apiQs, { method: 'POST' });
      if (!response.ok) throw new Error('Memory prune request failed');
      await response.json().catch(() => ({}));

      this.setPruneState(button, 'Done!', 'btn-ghost', true);
      const content = document.getElementById('memory-content');
      if (content) {
        htmx.ajax('GET', '/memory/content' + this.apiQs, {
          target: '#memory-content',
          swap: 'innerHTML',
          select: '#memory-inner',
        });
      }
      window.setTimeout(() => this.resetPruneButton(button), 2000);
    } catch (_) {
      this.setPruneState(button, 'Failed', 'btn-danger-fill', true);
      window.setTimeout(() => this.resetPruneButton(button), 2000);
    }
  }

  resetPruneButton(button) {
    this.setPruneState(button, 'Prune Now', 'btn-danger');
  }
}
