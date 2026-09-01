import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'channel_config_resolver.dart';

/// Loads config and parses every channel section.
///
/// Channel sections parse lazily per config instance, so a production load that
/// skipped this would drop channel parse warnings from [DartclawConfig.warnings]
/// and stop them blocking a hot reload. Every production load goes through here;
/// `DartclawConfig.load` is called nowhere else outside tests.
DartclawConfig loadDartclawConfig({
  String? configPath,
  Map<String, String>? cliOverrides,
  Map<String, String>? env,
  String? Function(String path)? fileReader,
}) {
  final config = DartclawConfig.load(
    configPath: configPath,
    cliOverrides: cliOverrides,
    env: env,
    fileReader: fileReader,
  );
  for (final channelType in channelConfigTypes) {
    resolveChannelConfig<Object>(config, channelType);
  }
  return config;
}
