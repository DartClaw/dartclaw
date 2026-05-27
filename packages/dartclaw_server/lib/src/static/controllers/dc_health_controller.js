export default class DcHealthController extends Stimulus.Controller {
  connect() {
    this.startPolling();
  }

  disconnect() {
    this.stopPolling();
  }

  startPolling() {
    if (this.pollTimer) return;
    this.pollTimer = window.setInterval(() => {
      const panel = this.element.matches('[data-health-refresh]')
        ? this.element
        : this.element.querySelector('[data-health-refresh]');
      if (!panel || !window.htmx) return;
      window.htmx.trigger(panel, 'refresh');
    }, 30000);
  }

  stopPolling() {
    if (!this.pollTimer) return;
    window.clearInterval(this.pollTimer);
    this.pollTimer = null;
  }
}
