import 'dart:convert';

const _encodedSkills = <String, Map<String, String>>{};

final Map<String, Map<String, String>> embeddedSkills = {
  for (final skill in _encodedSkills.entries)
    skill.key: {for (final file in skill.value.entries) file.key: utf8.decode(base64Decode(file.value))},
};
