export default class DcHelloController extends window.Stimulus.Controller {
  static targets = ['status'];

  connect() {
    this.#setConnectedState('true', 'dc-hello connected');
    console.info('dc-hello connect');
  }

  disconnect() {
    this.#setConnectedState('false', 'dc-hello disconnected');
    console.info('dc-hello disconnect');
  }

  #setConnectedState(connected, statusText) {
    this.element.dataset.dcHelloConnected = connected;
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = statusText;
    }
  }
}
