export default class DcWhatsappController extends Stimulus.Controller {
  static targets = ['qrImage', 'qrPlaceholder', 'countdown', 'active', 'expired'];
  static values = { qrDuration: Number };

  connect() {
    this.attachQrFallback();
    this.startCountdown();
  }

  disconnect() {
    if (this.timerId) {
      clearInterval(this.timerId);
      this.timerId = null;
    }
  }

  attachQrFallback() {
    this.qrImageTargets.forEach((img) => {
      const showFallback = () => {
        img.style.display = 'none';
        const placeholder = img.nextElementSibling;
        if (placeholder && placeholder.classList.contains('wa-qr-placeholder')) {
          placeholder.style.display = 'flex';
        }
      };

      img.addEventListener('error', showFallback);
      if (img.complete && img.naturalWidth === 0) {
        showFallback();
      }
    });
  }

  startCountdown() {
    if (this.timerId) {
      clearInterval(this.timerId);
      this.timerId = null;
    }

    if (!this.hasCountdownTarget || !this.hasActiveTarget || !this.hasExpiredTarget) {
      return;
    }

    const duration = this.qrDurationValue;
    if (!Number.isFinite(duration) || duration <= 0) {
      return;
    }

    let remaining = duration;
    const format = (seconds) => {
      const minutes = Math.floor(seconds / 60);
      const rest = seconds % 60;
      return `${minutes}:${String(rest).padStart(2, '0')}`;
    };

    this.countdownTarget.textContent = format(remaining);
    this.timerId = setInterval(() => {
      remaining -= 1;
      if (remaining <= 0) {
        clearInterval(this.timerId);
        this.timerId = null;
        this.activeTarget.style.display = 'none';
        this.expiredTarget.style.display = '';
        return;
      }
      this.countdownTarget.textContent = format(remaining);
    }, 1000);
  }
}
