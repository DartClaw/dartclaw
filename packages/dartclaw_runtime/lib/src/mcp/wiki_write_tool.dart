import 'package:dartclaw_core/dartclaw_core.dart';

import '../knowledge/wiki_page_store.dart';
import 'tool_schema.dart';

/// Principal recorded as the author of a tool-written wiki page.
const wikiWritePrincipal = 'agent-tool';

/// MCP tool that authors a wiki page through the one page-store entry point.
///
/// Slug containment, frontmatter emission, the provenance and confidence
/// vocabularies, the sources union, the atomic write and the shrink floor are
/// all [WikiPageStore.writePage]'s and are inherited unchanged. This tool adds
/// exactly one rule of its own: it refuses a slug that is not already canonical
/// rather than letting the store's sanitizer silently rewrite a model-supplied
/// value into a different page.
class WikiWriteTool implements McpTool {
  new({required WikiPageStore wiki, DateTime Function()? now}) : _wiki = wiki, _now = now ?? DateTime.now;

  final WikiPageStore _wiki;
  final DateTime Function() _now;

  @override
  String get name => 'wiki_write';

  @override
  String get description =>
      'Author a wiki page. The slug must already be lowercase words joined by hyphens. Writing over a stored page '
      'replaces its body, and a replacement materially shorter than what is stored is refused.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'slug': {'type': 'string', 'description': 'Page slug, lowercase with hyphens, e.g. "dart-roadmap".'},
      'title': {'type': 'string', 'description': 'Page title, emitted as the page\'s heading.'},
      'body': {'type': 'string', 'description': 'Page body in Markdown, below the title heading.'},
      'sources': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'What this page is derived from; unioned with the sources already recorded.',
      },
      'confidence': {'type': 'string', 'enum': WikiPageStore.confidenceLevels},
    },
    const ['slug', 'title', 'body', 'sources'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final slug = (args['slug'] as String).trim();
    // The store reduces any input to `[a-z0-9-]`, so a traversal slug would be
    // written as a different page rather than refused. Repairing a model-supplied
    // value is what the contract forbids, so a slug that is not already its own
    // canonical form fails the call.
    if (slug != WikiPageStore.pageSlug(slug)) {
      return toolError(
        'slug_refused',
        'slug must already be lowercase words joined by hyphens and contained in the wiki directory; '
            '"$slug" is not',
        {'slug': slug, 'canonical': WikiPageStore.pageSlug(slug)},
      );
    }

    final sources = [for (final source in args['sources'] as List) (source as String).trim()];
    final WikiPageWrite write;
    try {
      write = await _wiki.writePage(
        slug: slug,
        title: args['title'] as String,
        body: args['body'] as String,
        sources: sources,
        lastUpdatedBy: wikiWritePrincipal,
        now: _now(),
        confidence: args['confidence'] as String? ?? 'medium',
        // Settled here rather than inferred by the store: a stored page's body is
        // replaced by what this call authors. No removal is declared, so the
        // store's byte floor refuses a materially shorter body.
        merge: const WikiPageMerge(mode: WikiMergeMode.integrated),
      );
    } on WikiPageMergeRefused catch (error) {
      return toolError('shrink_floor', '$error', {
        'slug': slug,
        'stored_bytes': error.storedBytes,
        'merged_bytes': error.mergedBytes,
        'required_bytes': error.requiredBytes,
      });
    } on WikiPageUnreadable catch (error) {
      return toolError('page_unreadable', '$error', {'slug': slug});
    } on ArgumentError catch (error) {
      return toolError('invalid_request', '${error.message}', {'slug': slug});
    }
    return toolJson({'slug': slug, 'outcome': write.outcome.name, 'path': 'wiki/$slug.md', 'sources': sources});
  }
}
