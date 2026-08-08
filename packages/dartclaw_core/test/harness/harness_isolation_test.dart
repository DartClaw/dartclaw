import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  group('harness startup isolation (--setting-sources)', () {
    test('default non-containerized spawn omits --setting-sources project', () async {
      final capturedArgs = await startHarnessAndCaptureArgs();

      expect(capturedArgs, isNot(contains('--setting-sources')));
      expect(capturedArgs, isNot(contains('project')));
    });

    test('inherit_user_settings false passes --setting-sources project before --model', () async {
      final capturedArgs = await startHarnessAndCaptureArgs(providerOptions: const {'inherit_user_settings': false});

      final settingIdx = capturedArgs.indexOf('--setting-sources');
      final modelIdx = capturedArgs.indexOf('--model');
      expect(settingIdx, isNot(-1));
      expect(modelIdx, isNot(-1));
      expect(settingIdx, lessThan(modelIdx));
      expect(capturedArgs[settingIdx + 1], 'project');
    });

    test('--print and --output-format stream-json are also present (baseline)', () async {
      final capturedArgs = await startHarnessAndCaptureArgs();

      expect(capturedArgs, contains('--print'));
      expect(capturedArgs, contains('--output-format'));
      expect(capturedArgs, contains('stream-json'));
    });
  });
}
