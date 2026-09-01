import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Filters sensitive data from log output by delegating to [MessageRedactor].
///
/// Thin wrapper for backward compatibility within `dartclaw_runtime`. All
/// pattern matching and proportional-reveal logic lives in [MessageRedactor].
class LogRedactor {
  final MessageRedactor _redactor;

  new({MessageRedactor? redactor}) : _redactor = redactor ?? MessageRedactor();

  String redact(String input) => _redactor.redact(input);
}
