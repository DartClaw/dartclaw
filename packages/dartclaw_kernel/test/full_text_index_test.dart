import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('search values retain immutable snapshots of caller collections', () {
    final chunks = ['original'];
    final metadata = {'source': 'original'};
    final document = SearchDocument(id: 'entry', chunks: chunks, metadata: metadata, timestamp: DateTime.utc(2026));
    final result = SearchResult(
      id: 'entry',
      chunk: 'original',
      chunkIndex: 0,
      metadata: metadata,
      timestamp: DateTime.utc(2026),
      score: -1,
    );

    chunks[0] = 'changed';
    metadata['source'] = 'changed';
    expect(document.chunks, ['original']);
    expect(document.metadata, {'source': 'original'});
    expect(result.metadata, {'source': 'original'});
    expect(() => document.chunks[0] = 'changed', throwsUnsupportedError);
    expect(() => document.metadata['source'] = 'changed', throwsUnsupportedError);
    expect(() => result.metadata['source'] = 'changed', throwsUnsupportedError);
  });

  test('search results require a non-negative persisted chunk position', () {
    expect(
      () => SearchResult(id: 'entry', chunk: 'text', chunkIndex: -1, timestamp: DateTime.utc(2026), score: 0),
      throwsArgumentError,
    );
  });
}
