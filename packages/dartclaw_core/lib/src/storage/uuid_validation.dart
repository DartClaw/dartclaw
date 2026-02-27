final _uuidRegex = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Validates that [id] is a well-formed lowercase UUID v4 string.
bool isValidUuid(String id) => _uuidRegex.hasMatch(id);
