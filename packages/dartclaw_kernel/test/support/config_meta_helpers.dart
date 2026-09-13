part of '../config_meta_test.dart';

Set<String> _informativeWords(String description, String yamlPath) {
  const filler = {
    'a',
    'an',
    'the',
    'and',
    'or',
    'of',
    'to',
    'for',
    'in',
    'on',
    'is',
    'it',
    'its',
    'be',
    'as',
    'at',
    'by',
    'with',
    'this',
    'that',
    'when',
    'while',
    'whether',
    'which',
    'how',
    'what',
    'per',
    'use',
    'used',
    'uses',
    'set',
    'sets',
    'value',
    'values',
    'default',
    'defaults',
    'config',
    'configured',
    'configuration',
    'option',
    'setting',
    'settings',
  };
  final pathWords = yamlPath.toLowerCase().split(RegExp('[^a-z0-9]+')).where((word) => word.isNotEmpty).toSet();
  return description
      .toLowerCase()
      .split(RegExp('[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toSet()
      .difference(pathWords)
      .difference(filler);
}
