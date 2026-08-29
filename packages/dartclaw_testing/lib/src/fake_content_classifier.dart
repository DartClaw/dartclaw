import 'package:dartclaw_security/dartclaw_security.dart';

/// Configurable [ContentClassifier] fake.
///
/// Returns [result] for every classification, or throws when [shouldThrow] is
/// set so tests can exercise both the fail-open and fail-closed guard paths.
/// Both fields are mutable so a test can flip behavior between calls.
///
/// [callCount], [lastContent] and [lastTimeout] record what reached the
/// classifier, so a test can assert that a path classified nothing at all
/// rather than only asserting the outcome.
class FakeContentClassifier implements ContentClassifier {
  /// Classification returned when [shouldThrow] is false.
  String result;

  /// When true, [classify] throws instead of returning [result].
  bool shouldThrow;

  /// Number of [classify] calls received.
  var callCount = 0;

  /// Content passed to the most recent [classify] call, or null if never called.
  String? lastContent;

  /// Timeout passed to the most recent [classify] call, or null if never called.
  Duration? lastTimeout;

  new({this.result = 'safe', this.shouldThrow = false});

  @override
  Future<String> classify(String content, {Duration timeout = const Duration(seconds: 15)}) async {
    callCount++;
    lastContent = content;
    lastTimeout = timeout;
    if (shouldThrow) throw Exception('Classification error');
    return result;
  }
}
