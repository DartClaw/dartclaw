import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

SearchDocument memorySearchDocument({required String text, required String source}) => MemoryIndexProjection.document(
  text: text,
  source: source,
  category: 'general',
  createdAt: DateTime.utc(2026),
  locator: source,
)!;
