import 'guard.dart';
import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// NetworkGuardConfig
// ---------------------------------------------------------------------------

/// Configuration for the network guard — domain allowlist + exfiltration patterns.
class NetworkGuardConfig {
  /// Domains allowed for outbound network access.
  final Set<String> allowedDomains;

  /// Regexes that match suspicious exfiltration command structures.
  final List<RegExp> exfilPatterns;

  /// Optional per-agent domain additions keyed by agent id.
  final Map<String, Set<String>> agentOverrides;

  /// Creates a network guard configuration from precompiled rules.
  NetworkGuardConfig({required this.allowedDomains, required this.exfilPatterns, this.agentOverrides = const {}});

  /// Hardcoded safe defaults.
  factory NetworkGuardConfig.defaults() =>
      NetworkGuardConfig(allowedDomains: {..._defaultAllowedDomains}, exfilPatterns: _defaultExfilPatterns);

  /// Merges extra config from YAML with defaults.
  factory NetworkGuardConfig.fromYaml(Map<String, dynamic> yaml) {
    final defaults = NetworkGuardConfig.defaults();

    // Extra allowed domains
    final extraDomains = <String>{};
    final rawDomains = yaml['extra_allowed_domains'];
    if (rawDomains is List) {
      for (final d in rawDomains) {
        if (d is String) extraDomains.add(d);
      }
    }

    // Extra exfil patterns
    final extraExfil = <RegExp>[];
    final rawExfil = yaml['extra_exfil_patterns'];
    if (rawExfil is List) {
      for (final p in rawExfil) {
        if (p is String) {
          try {
            extraExfil.add(RegExp(p));
          } catch (_) {
            // Skip malformed regex
          }
        }
      }
    }

    // Per-agent overrides
    final overrides = <String, Set<String>>{};
    final rawOverrides = yaml['agent_overrides'];
    if (rawOverrides is Map) {
      for (final entry in rawOverrides.entries) {
        final agentId = entry.key.toString();
        final agentConfig = entry.value;
        if (agentConfig is Map) {
          final domains = <String>{};
          final rawAgentDomains = agentConfig['extra_domains'];
          if (rawAgentDomains is List) {
            for (final d in rawAgentDomains) {
              if (d is String) domains.add(d);
            }
          }
          if (domains.isNotEmpty) overrides[agentId] = domains;
        }
      }
    }

    return NetworkGuardConfig(
      allowedDomains: {...defaults.allowedDomains, ...extraDomains},
      exfilPatterns: [...defaults.exfilPatterns, ...extraExfil],
      agentOverrides: overrides,
    );
  }

  static const _defaultAllowedDomains = {
    'github.com',
    '*.github.com',
    'api.anthropic.com',
    'pypi.org',
    '*.pypi.org',
    'npmjs.com',
    '*.npmjs.com',
    'registry.npmjs.org',
    'pub.dev',
    '*.pub.dev',
    '*.googleapis.com',
    'dart.dev',
    '*.dart.dev',
    'crates.io',
    'rubygems.org',
    'stackoverflow.com',
  };

  static final _defaultExfilPatterns = [
    // Pipe to shell
    RegExp(r'curl\s+.*\|\s*(sh|bash|zsh|dash)\b'),
    RegExp(r'wget\s+.*-O\s*-\s*\|\s*(sh|bash)\b'),
    // POST data exfiltration
    RegExp(r'curl\s+.*(-d\s|--data\b|--data-raw\b|--data-binary\b|--data-urlencode\b|-F\s|--form\b)'),
    // Base64 encoding in pipe
    RegExp(r'\|\s*base64(\s|$)'),
  ];
}

// ---------------------------------------------------------------------------
// NetworkGuard
// ---------------------------------------------------------------------------

/// Domain allowlisting + exfiltration pattern detection guard.
///
/// Only evaluates on `beforeToolCall` for Bash and web_fetch tools.
class NetworkGuard extends Guard {
  @override
  String get name => 'network';

  @override
  String get category => 'network';

  /// Active domain and exfiltration policy used during evaluation.
  final NetworkGuardConfig config;

  /// Creates a network guard with defaults unless overridden.
  NetworkGuard({NetworkGuardConfig? config}) : config = config ?? NetworkGuardConfig.defaults();

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall') return GuardVerdict.pass();

    final toolName = context.toolName;
    final toolInput = context.toolInput;
    if (toolName == null || toolInput == null) return GuardVerdict.pass();

    if (toolName == 'Bash') {
      return _evaluateBash(toolInput['command'] as String? ?? '');
    }

    if (toolName == 'web_fetch') {
      return _evaluateWebFetch(toolInput['url'] as String? ?? '');
    }

    return GuardVerdict.pass();
  }

  GuardVerdict _evaluateBash(String command) {
    if (command.isEmpty) return GuardVerdict.pass();

    // Check exfiltration patterns first (command-structure checks)
    for (final pattern in config.exfilPatterns) {
      if (pattern.hasMatch(command)) {
        return GuardVerdict.block('Network blocked: exfiltration pattern detected');
      }
    }

    // Extract URLs and check domains
    final urls = _extractUrlsFromBash(command);
    for (final url in urls) {
      final verdict = _checkUrl(url);
      if (verdict != null) return verdict;
    }

    return GuardVerdict.pass();
  }

  GuardVerdict _evaluateWebFetch(String url) {
    if (url.isEmpty) return GuardVerdict.pass();
    return _checkUrl(url) ?? GuardVerdict.pass();
  }

  // -------------------------------------------------------------------------
  // URL checking
  // -------------------------------------------------------------------------

  GuardVerdict? _checkUrl(String urlString) {
    // Prepend scheme if missing (for IP detection)
    var toParse = urlString;
    if (!toParse.contains('://')) toParse = 'http://$toParse';

    final uri = Uri.tryParse(toParse);
    if (uri == null || uri.host.isEmpty) return null;

    final host = uri.host;

    // Block all direct IP addresses
    if (_isIpAddress(host)) {
      return GuardVerdict.block('Network blocked: direct IP address ($host)');
    }

    // Check domain against allowlist
    if (!_isDomainAllowed(host, config.allowedDomains)) {
      return GuardVerdict.block('Network blocked: domain not in allowlist ($host)');
    }

    return null;
  }

  // -------------------------------------------------------------------------
  // URL extraction from Bash commands
  // -------------------------------------------------------------------------

  static final _urlPattern = RegExp(r'https?://\S+');
  static final _gitSshPattern = RegExp(r'git\s+(?:clone|fetch|pull|push)\s+(?:[^|]*?\s+)??(git@\S+)');
  static final _dockerPullRegistry = RegExp(r'docker\s+pull\s+(\S+)');

  List<String> _extractUrlsFromBash(String command) {
    final urls = <String>{};

    // Generic URL extraction
    for (final match in _urlPattern.allMatches(command)) {
      urls.add(_cleanUrl(match.group(0)!));
    }

    // git@ SSH URLs
    for (final match in _gitSshPattern.allMatches(command)) {
      final url = match.group(1);
      if (url != null) urls.add(_cleanUrl(url));
    }

    // Docker pull — extract registry domain from image reference
    for (final match in _dockerPullRegistry.allMatches(command)) {
      final image = match.group(1);
      if (image != null && image.contains('.') && image.contains('/')) {
        // Image with registry: registry.example.com/image:tag
        final registry = image.split('/').first;
        urls.add('http://$registry');
      }
    }

    return urls.toList();
  }

  /// Strips trailing punctuation that may have been captured.
  static String _cleanUrl(String url) {
    // Strip trailing ), ], }, ;, ,, ', "
    return url.replaceAll(RegExp(r'[)\]};,\x27"]+$'), '');
  }

  // -------------------------------------------------------------------------
  // IP address detection
  // -------------------------------------------------------------------------

  static final _ipv4Pattern = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');

  static bool _isIpAddress(String host) {
    if (_ipv4Pattern.hasMatch(host)) return true;
    if (host.contains(':')) return true; // IPv6
    return false;
  }

  // -------------------------------------------------------------------------
  // Domain allowlist matching
  // -------------------------------------------------------------------------

  static bool _isDomainAllowed(String domain, Set<String> allowlist) {
    final lower = domain.toLowerCase();

    for (final entry in allowlist) {
      if (entry.startsWith('*.')) {
        // Wildcard: *.github.com matches api.github.com
        final suffix = entry.substring(1); // .github.com
        if (lower.endsWith(suffix)) return true;
      } else {
        if (lower == entry.toLowerCase()) return true;
      }
    }

    return false;
  }
}
