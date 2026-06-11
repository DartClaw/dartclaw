import 'package:dartclaw_security/dartclaw_security.dart';

/// Configurable [ContentClassifier] fake.
///
/// Returns [result] for every classification, or throws when [shouldThrow] is
/// set so tests can exercise both the fail-open and fail-closed guard paths.
/// Both fields are mutable so a test can flip behavior between calls.
class FakeContentClassifier implements ContentClassifier {
  /// Classification returned when [shouldThrow] is false.
  String result;

  /// When true, [classify] throws instead of returning [result].
  bool shouldThrow;

  FakeContentClassifier({this.result = 'safe', this.shouldThrow = false});

  @override
  Future<String> classify(String content, {Duration timeout = const Duration(seconds: 15)}) async {
    if (shouldThrow) throw Exception('Classification error');
    return result;
  }
}
