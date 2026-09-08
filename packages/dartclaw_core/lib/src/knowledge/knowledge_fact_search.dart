/// Builds a bound SQL predicate over authoritative fact fields.
abstract interface class KnowledgeFactSearch {
  /// Returns no predicate when [search] contains no searchable input.
  ({String sql, List<Object?> args})? predicate(String search);
}

/// Matches every whitespace-separated term as a case-insensitive substring.
final class SubstringFactSearch implements KnowledgeFactSearch {
  /// Creates the SQLite substring strategy.
  const new();

  @override
  ({String sql, List<Object?> args})? predicate(String search) {
    final terms = search
        .replaceAll('"', ' ')
        .split(RegExp(r'\s+'))
        .map((term) => term.trim().toLowerCase())
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return null;
    return (
      sql: [for (final _ in terms) "instr(lower(entity || ' ' || predicate || ' ' || value || ' ' || source), ?) > 0"]
          .join(' AND '),
      args: terms,
    );
  }
}

/// Searches fact fields with a PostgreSQL text-search configuration.
final class PostgresFactSearch implements KnowledgeFactSearch {
  final String _language;

  /// Uses a [language] already validated against the connected server.
  const new(this._language);

  @override
  ({String sql, List<Object?> args})? predicate(String search) {
    if (search.trim().isEmpty) return null;
    return (
      sql:
          "to_tsvector(?::regconfig, entity || ' ' || predicate || ' ' || value || ' ' || source) "
          '@@ websearch_to_tsquery(?::regconfig, ?)',
      args: [_language, _language, search],
    );
  }
}
