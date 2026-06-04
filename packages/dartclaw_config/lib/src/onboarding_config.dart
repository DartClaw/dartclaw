/// Configuration for conversational onboarding.
class OnboardingConfig {
  /// Number of days before an active onboarding sentinel stops being injected.
  final int expiryDays;

  /// Creates an onboarding config.
  const OnboardingConfig({this.expiryDays = 14});

  /// Default onboarding configuration.
  const OnboardingConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is OnboardingConfig && expiryDays == other.expiryDays;

  @override
  int get hashCode => expiryDays.hashCode;
}
