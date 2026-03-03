import '../channel_config.dart';

/// Configuration for the Signal channel via signal-cli subprocess.
class SignalConfig {
  final bool enabled;
  final String phoneNumber;
  final String executable;
  final String host;
  final int port;
  final int maxChunkSize;
  final RetryPolicy retryPolicy;

  const SignalConfig({
    this.enabled = false,
    this.phoneNumber = '',
    this.executable = 'signal-cli',
    this.host = '127.0.0.1',
    this.port = 8080,
    this.maxChunkSize = 4000,
    this.retryPolicy = const RetryPolicy(),
  });

  const SignalConfig.disabled() : this();

  factory SignalConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for signal.enabled: "${enabled.runtimeType}" — using default');
    }

    final phone = yaml['phone_number'];
    if (phone != null && phone is! String) {
      warns.add('Invalid type for signal.phone_number: "${phone.runtimeType}" — using default');
    }

    final executable = yaml['executable'];
    if (executable != null && executable is! String) {
      warns.add('Invalid type for signal.executable: "${executable.runtimeType}" — using default');
    }

    final host = yaml['host'];
    if (host != null && host is! String) {
      warns.add('Invalid type for signal.host: "${host.runtimeType}" — using default');
    }

    var port = 8080;
    final portRaw = yaml['port'];
    if (portRaw is int) {
      if (portRaw >= 1 && portRaw <= 65535) {
        port = portRaw;
      } else {
        warns.add('Invalid value for signal.port: $portRaw (must be 1-65535) — using default');
      }
    } else if (portRaw != null) {
      warns.add('Invalid type for signal.port: "${portRaw.runtimeType}" — using default');
    }

    var maxChunkSize = 4000;
    final mcs = yaml['max_chunk_size'];
    if (mcs is int) {
      maxChunkSize = mcs;
    } else if (mcs != null) {
      warns.add('Invalid type for signal.max_chunk_size: "${mcs.runtimeType}" — using default');
    }

    var retryPolicy = const RetryPolicy();
    final rpRaw = yaml['retry_policy'];
    if (rpRaw is Map) {
      retryPolicy = RetryPolicy.fromYaml(Map<String, dynamic>.from(rpRaw), warns);
    }

    return SignalConfig(
      enabled: enabled is bool ? enabled : false,
      phoneNumber: phone is String ? phone : '',
      executable: executable is String ? executable : 'signal-cli',
      host: host is String ? host : '127.0.0.1',
      port: port,
      maxChunkSize: maxChunkSize,
      retryPolicy: retryPolicy,
    );
  }
}
