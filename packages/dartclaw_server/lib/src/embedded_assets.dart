import 'dart:convert';

const _encodedTemplates = <String, String>{};
const _encodedStaticAssets = <String, String>{};
final Map<String, String> embeddedStaticMimeTypes = {};

final Map<String, String> embeddedTemplates = {
  for (final entry in _encodedTemplates.entries) entry.key: utf8.decode(base64Decode(entry.value)),
};

final Map<String, List<int>> embeddedStaticAssets = {
  for (final entry in _encodedStaticAssets.entries) entry.key: base64Decode(entry.value),
};
