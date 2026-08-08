/// Delay before a hover-opened popover closes, so the pointer can travel from
/// the marker into the popover without it disappearing underneath.
const CLOSE_DELAY_MS = 150;

export default class DcAttributionController extends Stimulus.Controller {
  static targets = ['popover'];

  connect() {
    this.handleDocumentClick = this.handleDocumentClick.bind(this);
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this);
    this.closeTimer = null;
    // A click-opened popover stays until dismissed; only hover auto-closes.
    this.pinned = false;
  }

  disconnect() {
    // Every listener and timer this controller owns must come down here, or a
    // removed controller keeps reacting after an HTMX swap.
    this.cancelClose();
    document.removeEventListener('click', this.handleDocumentClick, true);
    document.removeEventListener('keydown', this.handleDocumentKeydown);
  }

  /// A pointer is always hovering the marker when its click lands, so the
  /// popover is already open-but-unpinned by then. Treat that click as the
  /// pin, not as a close — otherwise click-to-pin is reachable only from the
  /// keyboard and a touch tap opens and immediately closes.
  toggle(event) {
    event.preventDefault();
    event.stopPropagation();
    if (this.isOpen && this.pinned) {
      this.hide();
    } else {
      this.open(true);
    }
  }

  show() {
    this.open(false);
  }

  open(pinned) {
    if (!this.hasPopoverTarget) return;
    this.cancelClose();
    if (pinned) this.pinned = true;
    this.popoverTarget.hidden = false;
    document.addEventListener('click', this.handleDocumentClick, true);
    document.addEventListener('keydown', this.handleDocumentKeydown);
  }

  hide() {
    if (!this.hasPopoverTarget) return;
    this.cancelClose();
    this.pinned = false;
    this.popoverTarget.hidden = true;
    document.removeEventListener('click', this.handleDocumentClick, true);
    document.removeEventListener('keydown', this.handleDocumentKeydown);
  }

  /// Arms the delayed close. Re-entering the marker or the popover cancels it,
  /// so a marker-to-marker traversal cannot leave a stale hide() pending.
  scheduleHide() {
    if (!this.isOpen || this.pinned) return;
    this.cancelClose();
    this.closeTimer = setTimeout(() => {
      this.closeTimer = null;
      this.hide();
    }, CLOSE_DELAY_MS);
  }

  cancelClose() {
    if (this.closeTimer !== null) {
      clearTimeout(this.closeTimer);
      this.closeTimer = null;
    }
  }

  handleDocumentClick(event) {
    if (this.element.contains(event.target)) return;
    this.hide();
  }

  handleDocumentKeydown(event) {
    if (event.key !== 'Escape') return;
    this.hide();
  }

  get isOpen() {
    return this.hasPopoverTarget && !this.popoverTarget.hidden;
  }
}
