import 'channel_type.dart';

/// Provides typed access to channel-specific configuration.
abstract interface class ChannelConfigProvider {
  /// Returns the config for [channelType], or that channel's disabled/default
  /// config when no explicit config exists.
  ///
  /// Throws [ArgumentError] if [T] does not match the config type for
  /// [channelType].
  T getChannelConfig<T>(ChannelType channelType);
}
