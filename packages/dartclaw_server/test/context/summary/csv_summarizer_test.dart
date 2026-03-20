import 'package:dartclaw_server/src/context/summary/csv_summarizer.dart';
import 'package:test/test.dart';

void main() {
  group('CsvSummarizer', () {
    test('summarizes standard CSV with mixed types', () {
      const csv = 'name,age,active,score\nAlice,32,true,98.5\nBob,28,false,77.2\nCarol,45,true,85.0';
      final result = CsvSummarizer.summarize(csv, 5000);
      expect(result, isNotNull);
      expect(result, contains('[Exploration summary — CSV'));
      expect(result, contains('Columns (4)'));
      expect(result, contains('name, age, active, score'));
      expect(result, contains('Rows: 3'));
      expect(result, contains('[Full content available'));
    });

    test('infers column types correctly', () {
      const csv = 'id,name,score,date\n1,Alice,98.5,2024-01-15\n2,Bob,77.2,2024-02-20';
      final result = CsvSummarizer.summarize(csv, 5000);
      expect(result, isNotNull);
      expect(result, contains('int'));
      expect(result, contains('string'));
      expect(result, contains('float'));
      expect(result, contains('date'));
    });

    test('handles CSV with quoted fields containing commas', () {
      const csv = 'name,address,age\n"Smith, John","123 Main St",30\n"Jones, Mary","456 Oak Ave",25';
      final result = CsvSummarizer.summarize(csv, 5000);
      expect(result, isNotNull);
      expect(result, contains('Columns (3)'));
      expect(result, contains('Rows: 2'));
    });

    test('handles TSV (tab delimiter)', () {
      const tsv = 'name\temail\tage\nAlice\talice@example.com\t32\nBob\tbob@example.com\t28';
      final result = CsvSummarizer.summarize(tsv, 5000, delimiter: '\t');
      expect(result, isNotNull);
      expect(result, contains('[Exploration summary — TSV'));
      expect(result, contains('Columns (3)'));
    });

    test('handles CSV with only header (no data rows)', () {
      const csv = 'name,email,age';
      final result = CsvSummarizer.summarize(csv, 1000);
      expect(result, isNotNull);
      expect(result, contains('Rows: 0'));
    });

    test('returns null for single-column CSV (not valid CSV)', () {
      final result = CsvSummarizer.summarize('singlecolumn\nrow1\nrow2', 1000);
      expect(result, isNull);
    });

    test('includes sample rows in output', () {
      const csv = 'name,age\nAlice,30\nBob,25\nCarol,35\nDave,28';
      final result = CsvSummarizer.summarize(csv, 5000);
      expect(result, isNotNull);
      expect(result, contains('Sample rows:'));
      expect(result, contains('Alice'));
    });

    test('formats row count with thousands separator for large datasets', () {
      final lines = ['name,age'];
      for (var i = 0; i < 15000; i++) {
        lines.add('Person$i,$i');
      }
      final result = CsvSummarizer.summarize(lines.join('\n'), 50000);
      expect(result, isNotNull);
      expect(result, contains('15,000'));
    });

    test('summary includes full content note', () {
      const csv = 'a,b,c\n1,2,3';
      final result = CsvSummarizer.summarize(csv, 5000);
      expect(result, contains('Full content available'));
      expect(result, contains('Use Read tool'));
    });
  });
}
