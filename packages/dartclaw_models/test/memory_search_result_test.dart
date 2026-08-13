import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  test('search snippets are bounded without splitting Unicode scalars', () {
    final result = MemorySearchResult(
      text: '${'x' * (MemorySearchResult.maxSnippetCharacters - 1)}🦅tail',
      source: 'source',
      score: 0,
    );

    expect(result.snippet.runes, hasLength(MemorySearchResult.maxSnippetCharacters));
    expect(result.snippet, endsWith('🦅'));
    expect(result.toRetrievalJson()['snippet'], result.snippet);
  });

  test('search outcome carries additive degradation without changing result iteration', () {
    const result = MemorySearchResult(text: 'Falcon', source: 'id', score: 0, locator: 'id');
    const degradation = MemorySearchDegradation(
      layer: 'wiki',
      locator: 'wiki/oversized.md',
      reason: 'sourceBytes',
      observed: 9,
      limit: 8,
    );
    const outcome = MemorySearchOutcome(
      results: [result],
      degradedLayers: ['qmd'],
      degradations: [degradation],
      canonicalRevision: 41,
    );

    expect(outcome.single.text, 'Falcon');
    expect(outcome.degradedLayers, ['qmd']);
    expect(outcome.degradations, [degradation]);
    expect(outcome.canonicalRevision, 41);
    expect(degradation.toJson(), {
      'layer': 'wiki',
      'locator': 'wiki/oversized.md',
      'reason': 'sourceBytes',
      'observed': 9,
      'limit': 8,
      'omittedCount': 0,
    });
  });

  test('canonical results reject generic and role-mismatched locators', () {
    MemorySearchResult build({String role = 'topic', String locator = 'memory_save'}) => MemorySearchResult.canonical(
      text: 'Falcon',
      source: locator,
      score: 0,
      role: role,
      provenance: 'session:one',
      locator: locator,
      entryId: locator,
      entryRevision: 1,
    );

    expect(build, throwsArgumentError);
    expect(() => build(role: 'wiki', locator: 'e907c4e7-0c55-43c0-95cd-ebf41c4f6721'), throwsArgumentError);
  });
}
