# Scenario: Native Windows Bash Step Qualification

Manual native-Windows qualification for workflow `type: bash`. Run from a Windows x64 checkout with Git Bash on
`PATH`. This scenario is not a browser/profile scenario and does not use the `test-scenario` runner.

## S1: Qualify Git Bash execution

### Preconditions

- Native Windows x64 host, not WSL
- Dart SDK available
- Git Bash installed and `where.exe bash` resolves its `bash.exe`
- Repository dependencies resolved with `dart pub get`

### Steps

1. From PowerShell at the repository root, create a qualification data directory whose native path contains spaces:

   ```powershell
   $dataDir = 'C:\DartClaw Bash Step Qualification'
   $workspaceDir = Join-Path $dataDir 'workspace with spaces'
   $workflowDir = Join-Path $dataDir 'workflows\custom'
   New-Item -ItemType Directory -Force $workspaceDir, $workflowDir | Out-Null
   Set-Content -NoNewline (Join-Path $workspaceDir 'fixture file.txt') 'relative-file-ok'
   ```

2. Write `C:\DartClaw Bash Step Qualification\dartclaw.yaml`:

   ```yaml
   data_dir: 'C:\DartClaw Bash Step Qualification'
   security:
     bash_step:
       env_allowlist:
         - DARTCLAW_BASH_QUALIFICATION
   ```

3. Write `C:\DartClaw Bash Step Qualification\workflows\custom\windows-bash-step-qualification.yaml`:

   ```yaml
   name: windows-bash-step-qualification
   description: Qualify native Windows Git Bash workflow-step behavior
   steps:
     - id: qualify-bash
       name: Qualify Bash
       type: bash
       workdir: 'C:\DartClaw Bash Step Qualification\workspace with spaces'
       script: |
         set -eu
         printf 'git_bash_version=%s\n' "$(bash --version | head -n 1)"
         printf 'git_bash_pwd=%s\n' "$(pwd)"
         printf 'relative_file=%s\n' "$(cat './fixture file.txt')"
         printf 'allowlisted_env=%s\n' "$DARTCLAW_BASH_QUALIFICATION"
         printf 'posix_result=%s\n' "$(printf 'one\ntwo\n' | wc -l | tr -d ' ')"
       outputs:
         qualification_output:
           format: text
   ```

4. Record the native cwd, OS/architecture, source revision, resolved Bash path, and artifact/source under test:

   ```powershell
   Get-Location
   [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
   [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
   git rev-parse HEAD
   where.exe bash
   dart --version
   ```

5. Set the allowlisted canary and execute the workflow through the current checkout:

   ```powershell
   $env:DARTCLAW_BASH_QUALIFICATION = 'allowlist-ok'
   dart run dartclaw_cli:dartclaw workflow run windows-bash-step-qualification `
     --standalone `
     --force `
     --json `
     --no-skill-bootstrap `
     --config (Join-Path $dataDir 'dartclaw.yaml')
   ```

6. Confirm the command output contains the Step 4 environment metadata. If a local report is useful, save it under
   `.agent_temp/`.

### Expected

- The workflow completes successfully and `qualify-bash.status` is `success` with exit code `0`.
- `git_bash_version` identifies Git Bash.
- `git_bash_pwd` is the POSIX-style mapping of the native cwd containing a drive letter and spaces.
- `relative_file=relative-file-ok` proves quoted relative access to a filename containing spaces.
- `allowlisted_env=allowlist-ok` proves configured environment propagation.
- `posix_result=2` proves basic POSIX pipeline execution.
- The command output names the native Windows OS/architecture, Git revision, Dart version, and source checkout or release
  artifact tested.
- No claim is made that arbitrary Windows paths inside command arguments are translated.
