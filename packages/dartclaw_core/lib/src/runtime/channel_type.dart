/// The transport channel type for inbound messages.
enum ChannelType {
  /// Built-in browser-based chat surface.
  web,

  /// WhatsApp integration via the GOWA sidecar.
  whatsapp,

  /// Signal integration via signal-cli.
  signal,

  /// Google Chat integration via the Google Chat REST API.
  googlechat,
}
