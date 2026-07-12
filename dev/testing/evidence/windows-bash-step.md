# Native Windows Bash-Step Qualification Evidence

**Status**: NOT RUN

No native Windows host was available during the 2026-07-11 implementation run. This file is intentionally not a
passing qualification record. Run `dev/testing/scenarios/windows-bash-step.md` on native Windows x64 with Git Bash,
then replace this block with the latest completed run containing:

- run timestamp and operator
- native OS and architecture
- source revision plus checkout/release artifact under test
- Dart version and resolved `bash.exe`
- native cwd containing a drive letter and spaces
- Git Bash POSIX-style `pwd`
- quoted relative-file result for `fixture file.txt`
- allowlisted environment result
- basic POSIX command result
- Git Bash version
- workflow status and exit code
