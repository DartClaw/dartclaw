import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

/// Typed channel configs parsed off a given [DartclawConfig], keyed by instance.
///
/// Resolution stays lazy per config because `resolveChannelConfig` must work on
/// any [DartclawConfig], including instances `loadDartclawConfig` never produced
/// - `copyWith` results and test fixtures among them.
final Expando<Map<ChannelType, Object>> _channelConfigCache = Expando('channelConfigCache');

/// Returns [config]'s channel-specific config of type [T] for [channelType].
///
/// The section is parsed once per [config] instance, so its parse warnings
/// reach [DartclawConfig.warnings] exactly once.
///
/// Throws [ArgumentError] when [channelType] has no config section, or when the
/// resolved config is not assignable to [T].
T resolveChannelConfig<T>(DartclawConfig config, ChannelType channelType) {
  if (channelType == ChannelType.web) {
    throw ArgumentError('No channel config is defined for ${channelType.name}.');
  }

  final cache = _channelConfigCache[config] ??= <ChannelType, Object>{};
  final resolved = cache.putIfAbsent(channelType, () => _parseChannelConfig(config, channelType));
  if (resolved is! T) {
    throw ArgumentError('Channel ${channelType.name} expects ${resolved.runtimeType}, which is not assignable to $T.');
  }
  return resolved as T;
}

/// Every channel that has a config section — every [ChannelType] but
/// [ChannelType.web], derived so a new channel cannot be left unprimed.
Iterable<ChannelType> get channelConfigTypes => ChannelType.values.where((type) => type != ChannelType.web);

Object _parseChannelConfig(DartclawConfig config, ChannelType channelType) {
  Map<String, dynamic> section(String key) => config.channels.channelConfigs[key] ?? const <String, dynamic>{};

  return config.parseWithLoadWarnings<Object>(
    (warns) => switch (channelType) {
      ChannelType.googlechat => GoogleChatConfig.fromYaml(section('google_chat'), warns),
      ChannelType.signal => SignalConfig.fromYaml(section('signal'), warns),
      ChannelType.whatsapp => WhatsAppConfig.fromYaml(section('whatsapp'), warns),
      ChannelType.web => throw ArgumentError('No channel config is defined for ${channelType.name}.'),
    },
  );
}
