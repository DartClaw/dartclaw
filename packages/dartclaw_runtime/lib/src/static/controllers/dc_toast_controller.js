export default class DcToastController extends Stimulus.Controller {
  connect() {
    this.showHandler = this.showHandler.bind(this);
    document.body.addEventListener('dc:toast', this.showHandler);
  }

  disconnect() {
    document.body.removeEventListener('dc:toast', this.showHandler);
  }

  showHandler(event) {
    const detail = event && event.detail;
    if (!detail || typeof window.dartclaw?.ui?.showToast !== 'function') return;
    window.dartclaw.ui.showToast(detail.type || 'info', detail.message || '');
  }
}
