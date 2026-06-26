export default class DcAttributionController extends Stimulus.Controller {
  static targets = ['popover'];

  connect() {
    this.handleDocumentClick = this.handleDocumentClick.bind(this);
  }

  disconnect() {
    document.removeEventListener('click', this.handleDocumentClick, true);
  }

  toggle(event) {
    event.preventDefault();
    event.stopPropagation();
    if (this.isOpen) {
      this.hide();
    } else {
      this.show();
    }
  }

  show() {
    if (!this.hasPopoverTarget) return;
    this.popoverTarget.hidden = false;
    document.addEventListener('click', this.handleDocumentClick, true);
  }

  hide() {
    if (!this.hasPopoverTarget) return;
    this.popoverTarget.hidden = true;
    document.removeEventListener('click', this.handleDocumentClick, true);
  }

  handleDocumentClick(event) {
    if (this.element.contains(event.target)) return;
    this.hide();
  }

  get isOpen() {
    return this.hasPopoverTarget && !this.popoverTarget.hidden;
  }
}
