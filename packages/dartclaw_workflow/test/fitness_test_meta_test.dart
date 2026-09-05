import 'package:test/test.dart';

import 'fitness_support.dart';

void main() {
  test('F-SIZE-1 failure message names the file, current LOC, and ceiling', () {
    final message = sizeViolationMessage(
      'packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart',
      901,
      800,
    );

    expect(message, isNotNull);
    expect(message, contains('workflow_executor.dart'));
    expect(message, contains('901'));
    expect(message, contains('800'));
  });

  group('the member count separates declarations from statements', () {
    List<String> namesIn(String source) => [
      for (final metric in extractMethodMetrics('probe.dart', sanitizeDartSourceForFitness(source)))
        '${metric.className ?? '#top'}::${metric.methodName}',
    ];

    test('a field initialiser with wrapped arguments is not a member', () {
      // The formatter breaks a long constructor call across lines, and its
      // opening line has a declaration's shape. It used to be counted twice,
      // against a class that had already closed.
      final names = namesIn(r'''
class Probe {
  final int a;

  Probe(this.a);
}

final one = Probe(
  1,
);

final two = Probe(
  2,
);
''');
      expect(names, ['Probe::Probe']);
    });

    test('a `;`-bodied constructor and a redirecting one are both counted', () {
      final names = namesIn(r'''
class Probe {
  final int a;

  Probe(this.a);

  Probe.zero() : this(0);
}
''');
      expect(names, ['Probe::Probe', 'Probe::Probe.zero']);
    });

    test('the `new` primary-constructor name is a member, not a statement', () {
      final names = namesIn(r'''
class Probe {
  final int a;

  const new({this.a = 0});
}
''');
      expect(names, ['Probe::new']);
    });

    test('calls inside a body are not members, and the class still closes', () {
      final names = namesIn(r'''
class Probe {
  List<int> doubled(List<int> xs) {
    final scaled = xs.map((e) => e * 2).toList();
    return scaled;
  }
}

String topLevel() => 'x';
''');
      expect(names, ['Probe::doubled', '#top::topLevel']);
    });

    test('a map entry and a named argument do not supply a declaration head', () {
      final names = namesIn(r'''
class Probe {
  Map<String, Object?> toJson() => {
    'hunks': hunks.map((h) => h.toJson()).toList(),
  };

  Probe rebuild(Map<String, Object?> json) => Probe(
    status: Status.values.byName(json['status'] as String),
  );
}
''');
      expect(names, ['Probe::toJson', 'Probe::rebuild']);
    });

    test('a generic or record return type holding a paren keeps its member', () {
      final names = namesIn(r'''
class Probe {
  Future<(int, String?)> checkBudget(int n) async => (n, null);

  Map<String, ({int a, String? b})> parse(String s) {
    return const {};
  }

  void operator []=(String key, Object? value) => _data[key] = value;
}
''');
      expect(names, ['Probe::checkBudget', 'Probe::parse', 'Probe::operator []=']);
    });
  });
}
