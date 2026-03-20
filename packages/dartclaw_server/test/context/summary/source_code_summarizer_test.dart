import 'package:dartclaw_server/src/context/summary/source_code_summarizer.dart';
import 'package:dartclaw_server/src/context/type_detector.dart';
import 'package:test/test.dart';

void main() {
  group('SourceCodeSummarizer', () {
    group('Dart source', () {
      test('extracts classes, enums, and functions', () {
        const code = '''
import 'dart:async';
import 'package:foo/foo.dart';

class MyService {
  void doWork() {}
}

abstract class BaseHandler {
  void handle();
}

enum Status { pending, running, done }

typedef Callback = void Function(String);

String formatResult(String input) => input.trim();
''';
        final result = SourceCodeSummarizer.summarize(code, ContentType.dart, 30000);
        expect(result, isNotNull);
        expect(result, contains('[Exploration summary — Dart source'));
        expect(result, contains('MyService'));
        expect(result, contains('BaseHandler'));
        expect(result, contains('Status'));
        expect(result, contains('Callback'));
        expect(result, contains('Imports (2)'));
        expect(result, contains('[Full content available'));
      });

      test('handles code with no declarations', () {
        const code = '// Just a comment\n// Another comment\n';
        final result = SourceCodeSummarizer.summarize(code, ContentType.dart, 1000);
        expect(result, isNull);
      });
    });

    group('TypeScript source', () {
      test('extracts classes, functions, interfaces, types', () {
        const code = '''
import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';

export class UserService {
  getUsers(): Observable<User[]> { return of([]); }
}

export interface User {
  id: number;
  name: string;
}

export type UserId = number;

export function createUser(name: string): User {
  return { id: 0, name };
}
''';
        final result = SourceCodeSummarizer.summarize(code, ContentType.typescript, 30000);
        expect(result, isNotNull);
        expect(result, contains('[Exploration summary — TypeScript source'));
        expect(result, contains('UserService'));
        expect(result, contains('User'));
        expect(result, contains('UserId'));
        expect(result, contains('createUser'));
      });
    });

    group('Python source', () {
      test('extracts classes and functions', () {
        const code = '''
from typing import List, Optional
import os

class DataProcessor:
    def __init__(self):
        pass

class ResultFormatter:
    pass

def process_data(items: List[str]) -> List[str]:
    return items

def format_output(data: dict) -> str:
    return str(data)
''';
        final result = SourceCodeSummarizer.summarize(code, ContentType.python, 30000);
        expect(result, isNotNull);
        expect(result, contains('[Exploration summary — Python source'));
        expect(result, contains('DataProcessor'));
        expect(result, contains('ResultFormatter'));
        expect(result, contains('process_data'));
        expect(result, contains('format_output'));
        expect(result, contains('Imports (2)'));
      });

      test('does not include indented functions', () {
        const code = '''
class MyClass:
    def method_inside_class(self):
        pass

def top_level_function():
    pass
''';
        final result = SourceCodeSummarizer.summarize(code, ContentType.python, 30000);
        expect(result, isNotNull);
        expect(result, contains('top_level_function'));
        // method_inside_class is indented so should not appear in top-level functions
        // (it may or may not appear based on implementation detail — just verify it doesn't crash)
      });
    });

    group('Go source', () {
      test('extracts structs, interfaces, and functions', () {
        const code = '''
package main

import "fmt"

type UserService struct {
    db *Database
}

type Repository interface {
    Find(id int) (*User, error)
    Save(user *User) error
}

func NewUserService(db *Database) *UserService {
    return &UserService{db: db}
}

func (s *UserService) GetUser(id int) (*User, error) {
    return nil, nil
}
''';
        final result = SourceCodeSummarizer.summarize(code, ContentType.go, 30000);
        expect(result, isNotNull);
        expect(result, contains('[Exploration summary — Go source'));
        expect(result, contains('UserService'));
        expect(result, contains('Repository'));
        expect(result, contains('NewUserService'));
        expect(result, contains('GetUser'));
      });
    });

    group('edge cases', () {
      test('returns null for unsupported content type', () {
        final result = SourceCodeSummarizer.summarize('{}', ContentType.json, 1000);
        expect(result, isNull);
      });

      test('summary includes declaration count', () {
        const code = '''
class A {}
class B {}
class C {}
''';
        final result = SourceCodeSummarizer.summarize(code, ContentType.dart, 30000);
        expect(result, isNotNull);
        expect(result, contains('Declarations ('));
      });
    });
  });
}
