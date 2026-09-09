Intent Context: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/phase-b/s07-native-packaging-and-platform-proof-harness.md`

## Fix

None.

## Note

None.

Targeted closure: the online acquisition path now follows a maximum of five redirects and retains exact size/SHA-256 verification before atomic cache or stage publication; focused regressions cover archive and model redirect chains plus exhausted redirects with no publication. Process observation now collects output through cancelable subscriptions, escalates SIGTERM to SIGKILL after bounded grace periods, bounds output closure, cancels subscriptions, records `outputStreamsClosed`, and requires it for a passing observation/evidence record. Real SIGTERM-resistant-child, inherited-grandchild-pipe and injected incomplete-output regressions cover the prior lifecycle gap.

Applied inline severity calibration (Findings Filter skipped: no Critical findings and <=5 total).

Guardrails Coverage: 12 checked, 0 findings

Files: .github/workflows/release-binaries.yml, apps/dartclaw_cli/test/tool/build_tool_test.dart, apps/dartclaw_cli/test/tool/native_artifact_preparation_test.dart, apps/dartclaw_cli/test/tool/native_embedding_platform_gate_test.dart, apps/dartclaw_cli/test/tool/native_packaging_contract_test.dart, apps/dartclaw_cli/test/tool/release_binaries_workflow_test.dart, apps/dartclaw_cli/tool/native_artifact_preparation.dart, apps/dartclaw_cli/tool/native_embedding_platform_gate.dart, apps/dartclaw_cli/tool/native_embedding_probe.dart, apps/dartclaw_cli/tool/prepare_native_embedding_model.dart, dev/native_artifacts.json, dev/tools/build.sh, dev/tools/build_windows.ps1, dev/tools/stage_native_build_workspace.dart

Story-Gate: PASS @ c4f5cf4577ed+89f3797d6187
