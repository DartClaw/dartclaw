import 'package:dartclaw_core/dartclaw_core.dart';

/// Filters sensitive data from log output by delegating to [MessageRedactor].
///
/// Thin wrapper for backward compatibility within `dartclaw_server`. All
/// pattern matching and proportional-reveal logic lives in [MessageRedactor].
class LogRedactor {
  final MessageRedactor _redactor;

  LogRedactor({MessageRedactor? redactor}) : _redactor = redactor ?? MessageRedactor();

  String redact(String input) => _redactor.redact(input);
}
