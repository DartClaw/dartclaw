export default class DcDialogController extends Stimulus.Controller {
  connect() {
    this.handleClick = this.handleClick.bind(this);
    this.element.addEventListener('click', this.handleClick);
    if (typeof this.element.showModal === 'function' && !this.element.open) {
      this.element.showModal();
    }
  }

  disconnect() {
    this.element.removeEventListener('click', this.handleClick);
  }

  handleClick(event) {
    if (event.target.closest('[data-dialog-close]')) this.element.close();
  }
}
