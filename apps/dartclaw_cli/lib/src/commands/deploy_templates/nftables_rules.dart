/// Generates Linux nftables rules for egress allowlisting.
String generateNftablesRules({
  List<String> allowedHosts = const ['api.anthropic.com'],
}) {
  final buffer = StringBuffer();
  buffer.writeln('#!/usr/sbin/nft -f');
  buffer.writeln('# DartClaw egress allowlist — apply via: sudo nft -f /path/to/nftables.conf');
  buffer.writeln();
  buffer.writeln('table inet dartclaw {');
  buffer.writeln('  chain output {');
  buffer.writeln('    type filter hook output priority 0; policy drop;');
  buffer.writeln();
  buffer.writeln('    # Allow established connections');
  buffer.writeln('    ct state established,related accept');
  buffer.writeln();
  buffer.writeln('    # Allow loopback');
  buffer.writeln('    oifname "lo" accept');
  buffer.writeln();
  buffer.writeln('    # DNS resolution');
  buffer.writeln('    ip daddr { 1.1.1.1, 8.8.8.8 } tcp dport 53 accept');
  buffer.writeln('    ip daddr { 1.1.1.1, 8.8.8.8 } udp dport 53 accept');

  // Allowed hosts
  for (final host in allowedHosts) {
    buffer.writeln('    ip daddr $host tcp dport 443 accept');
  }

  buffer.writeln('  }');
  buffer.writeln('}');

  return buffer.toString();
}
