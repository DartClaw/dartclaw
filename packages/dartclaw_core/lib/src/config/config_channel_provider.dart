part of 'dartclaw_config.dart';

final Expando<Map<ChannelType, Object>> _lazyChannelConfigCache = Expando('channelConfigCache');
final Expando<List<String>> _lazyChannelConfigWarnings = Expando('channelConfigWarnings');
final Map<ChannelType, Object Function(Map<String, dynamic>, List<String>)> _channelConfigParsers = {};

void _registerChannelConfigParser(
  ChannelType channelType,
  Object Function(Map<String, dynamic> yaml, List<String> warns) parser,
) {
  if (channelType == ChannelType.web) {
    throw ArgumentError('No channel config is defined for ${channelType.name}.');
  }

  _channelConfigParsers[channelType] = parser;
}

void _primeChannelConfigsForConfig(DartclawConfig config) {
  for (final channelType in _channelConfigParsers.keys) {
    _channelConfigForConfig(config, channelType);
  }
}

Object _channelConfigForConfig(DartclawConfig config, ChannelType channelType) {
  if (channelType == ChannelType.web) {
    throw ArgumentError('No channel config is defined for ${channelType.name}.');
  }

  final cache = _lazyChannelConfigCache[config] ??= <ChannelType, Object>{};
  return cache.putIfAbsent(channelType, () => _parseChannelConfig(config, channelType));
}

Object _parseChannelConfig(DartclawConfig config, ChannelType channelType) {
  final parser = _channelConfigParsers[channelType];
  if (parser == null) {
    // Missing registration is still a bootstrap error. Hosts are expected to
    // import the channel package so its top-level self-registration runs
    // before [DartclawConfig.load] primes channel configs.
    throw StateError(
      'No config parser registered for ${channelType.name}. '
      'Import that channel package before requesting its config.',
    );
  }

  final warns = _warningSinkForConfig(config);
  final configKey = switch (channelType) {
    ChannelType.googlechat => 'google_chat',
    ChannelType.signal => 'signal',
    ChannelType.whatsapp => 'whatsapp',
    ChannelType.web => throw ArgumentError('No channel config is defined for ${channelType.name}.'),
  };

  return parser(config.channels.channelConfigs[configKey] ?? const <String, dynamic>{}, warns);
}

List<String> _warningSinkForConfig(DartclawConfig config) =>
    _lazyChannelConfigWarnings[config] ??= List<String>.of(config._warnings);

final class _ConfigChannelConfigProvider implements ChannelConfigProvider {
  final DartclawConfig _config;

  _ConfigChannelConfigProvider(this._config);

  @override
  T getChannelConfig<T>(ChannelType channelType) => _config.getChannelConfig<T>(channelType);
}
