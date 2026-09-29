import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'composed_search_backend.dart';
import 'lexical_search_backend.dart';
import 'wiki_search_source.dart';

/// Creates lexical search, optionally extended by [personalBackend].
SearchBackend createSearchBackend({
  required FullTextIndex index,
  String? workspaceDir,
  SearchIndexHealthProbe? indexHealthProbe,
  SearchBackend? personalBackend,
}) {
  final wikiSearch = workspaceDir == null ? null : WikiSearchSource(workspaceDir: workspaceDir);
  final personal = personalBackend ?? LexicalSearchBackend(index: index);

  return wikiSearch == null && indexHealthProbe == null
      ? personal
      : ComposedSearchBackend(personal: personal, wiki: wikiSearch, indexHealthProbe: indexHealthProbe);
}
