import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_scheduling_controller.js');

  test('typing into a served cron form updates its advisory preview without a request', () async {
    await expectNodeHarness(_previewHarness, [(await controller).absolute.uri.toString()]);
  });
}

const _previewHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

let requests = 0;
globalThis.fetch = () => { requests += 1; throw new Error('preview made a request'); };
globalThis.Stimulus = { Controller: class {} };
globalThis.document = { getElementById: () => null };

const source = await readFile(new URL(process.argv[1]), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
const output = { textContent: '' };
globalThis.document.getElementById = id => id === 'cron-preview' ? output : null;

controller.updateJobCronPreview({ currentTarget: { value: '0 7 * * *' } });
assert(output.textContent === 'Daily at 7:00 AM', 'served form preview did not update');
assert(requests === 0, 'advisory preview performed a request');
''';
