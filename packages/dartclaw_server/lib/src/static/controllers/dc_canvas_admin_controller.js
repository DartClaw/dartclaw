import { escapeHtml } from './shared.js';

function sanitizeQrSvg(svg) {
  if (!svg || !window.DOMPurify) return '';
  return window.DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true } });
}

export default class DcCanvasAdminController extends Stimulus.Controller {
  static targets = ['permission', 'label', 'list'];
  static values = { sessionKey: String };

  connect() {
    this.loadShares();
  }

  async generateShare() {
    const payload = {
      sessionKey: this.sessionKeyValue,
      permission: this.permissionTarget.value,
      label: this.labelTarget.value.trim() || null,
    };

    const response = await fetch('/api/canvas/share', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    });

    if (!response.ok) return;
    this.labelTarget.value = '';
    await this.loadShares();
  }

  async listClick(event) {
    const copyButton = event.target.closest('[data-copy-url]');
    if (copyButton) {
      const copyUrl = copyButton.getAttribute('data-copy-url');
      if (copyUrl && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(copyUrl);
      }
      return;
    }

    const revokeButton = event.target.closest('[data-revoke-token]');
    if (revokeButton) {
      const token = revokeButton.getAttribute('data-revoke-token');
      await fetch(`/api/canvas/share/${encodeURIComponent(token)}`, { method: 'DELETE' });
      await this.loadShares();
      return;
    }

    const toggleButton = event.target.closest('[data-toggle-qr]');
    if (!toggleButton) return;
    const card = toggleButton.closest('.canvas-share-item');
    const qr = card?.querySelector('.canvas-qr');
    if (!qr) return;

    const isHidden = qr.hasAttribute('hidden');
    if (isHidden) {
      qr.removeAttribute('hidden');
      toggleButton.textContent = 'Hide QR';
    } else {
      qr.setAttribute('hidden', '');
      toggleButton.textContent = 'Show QR';
    }
  }

  async loadShares() {
    const response = await fetch(`/api/canvas/share?sessionKey=${encodeURIComponent(this.sessionKeyValue)}`);
    const items = response.ok ? await response.json() : [];
    this.renderShares(items);
  }

  renderShares(items) {
    if (!items.length) {
      this.listTarget.innerHTML = '<div class="canvas-empty-state">No active share links yet.</div>';
      return;
    }

    this.listTarget.innerHTML = items.map((item) => {
      const label = item.label ? `<strong>${escapeHtml(item.label)}</strong>` : '<strong>Untitled link</strong>';
      const qrBlock = item.qrSvg ? `<div class="canvas-qr" hidden>${sanitizeQrSvg(item.qrSvg)}</div>` : '';
      return `
        <article class="canvas-share-item" data-token="${escapeHtml(item.token)}">
          <div>${label}</div>
          <div class="canvas-share-meta">
            <span>${escapeHtml(item.permission)}</span>
            <span>Expires ${escapeHtml(item.expiresAt)}</span>
          </div>
          <div class="canvas-share-url">${escapeHtml(item.url)}</div>
          <div class="canvas-share-actions">
            <button class="btn btn-sm" type="button" data-copy-url="${escapeHtml(item.url)}">Copy</button>
            <button class="btn btn-sm" type="button" data-toggle-qr>Show QR</button>
            <button class="btn btn-sm btn-danger" type="button" data-revoke-token="${escapeHtml(item.token)}">Revoke</button>
          </div>
          ${qrBlock}
        </article>
      `;
    }).join('');
  }
}
