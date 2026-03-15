/// Generates macOS pf firewall rules for egress allowlisting.
///
/// Note: These rules do NOT affect Docker Desktop VM container traffic.
/// Container egress is controlled by `network:none` + credential proxy.
/// These rules provide host-level defense-in-depth.
String generatePfRules({List<String> allowedHosts = const ['api.anthropic.com']}) {
  final buffer = StringBuffer();
  buffer.writeln('# DartClaw egress allowlist — load via: sudo pfctl -f /path/to/pf.conf');
  buffer.writeln('# Host-level defense-in-depth (does not affect Docker VM traffic)');
  buffer.writeln();
  buffer.writeln('anchor "dartclaw" {');

  // DNS resolution
  buffer.writeln('  pass out proto tcp from any to 1.1.1.1 port 53');
  buffer.writeln('  pass out proto udp from any to 1.1.1.1 port 53');
  buffer.writeln('  pass out proto tcp from any to 8.8.8.8 port 53');
  buffer.writeln('  pass out proto udp from any to 8.8.8.8 port 53');

  // Allowed hosts
  for (final host in allowedHosts) {
    buffer.writeln('  pass out proto tcp from any to $host port 443');
  }

  buffer.writeln('  block out all');
  buffer.writeln('}');

  return buffer.toString();
}
