// whatsapp.js - DartClaw WhatsApp pairing page logic
'use strict';

// QR image fallback: when a .wa-qr-img fails to load, hide it and show the
// sibling .wa-qr-placeholder. Handles both error events and already-failed images.
function initQrFallback() {
  document.querySelectorAll('.wa-qr-img').forEach(img => {
    const show = () => {
      const ph = img.nextElementSibling;
      if (ph?.classList.contains('wa-qr-placeholder')) {
        img.style.display = 'none';
        ph.style.display = 'flex';
      }
    };
    img.addEventListener('error', show);
    if (img.complete && img.naturalWidth === 0) show();
  });
}

// QR countdown timer: reads data-qr-duration from .wa-qr-section, counts down,
// and swaps to the expired state when it reaches 0.
let _qrCountdownTimer = null;
function initQrCountdown() {
  if (_qrCountdownTimer) { clearInterval(_qrCountdownTimer); _qrCountdownTimer = null; }

  const section = document.querySelector('.wa-qr-section');
  if (!section) return;

  const duration = parseInt(section.dataset.qrDuration, 10);
  if (!duration || duration <= 0) return;

  const countdownEl = section.querySelector('.wa-countdown');
  const activeEl = section.querySelector('.wa-qr-active');
  const expiredEl = section.querySelector('.wa-qr-expired');
  if (!countdownEl || !activeEl || !expiredEl) return;

  let remaining = duration;
  const fmt = (s) => {
    const m = Math.floor(s / 60);
    const sec = s % 60;
    return m > 0 ? `${m}:${String(sec).padStart(2, '0')}` : `0:${String(sec).padStart(2, '0')}`;
  };
  countdownEl.textContent = fmt(remaining);

  _qrCountdownTimer = setInterval(() => {
    remaining--;
    if (remaining <= 0) {
      clearInterval(_qrCountdownTimer);
      _qrCountdownTimer = null;
      activeEl.style.display = 'none';
      expiredEl.style.display = '';
    } else {
      countdownEl.textContent = fmt(remaining);
    }
  }, 1000);
}
