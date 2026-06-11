/// Test marker thrown in place of `dart:io`'s `exit`, capturing the exit code
/// so command tests can assert on it without terminating the process.
class FakeExit implements Exception {
  final int code;
  const FakeExit(this.code);
}

/// Drop-in `exitFn` that throws [FakeExit] instead of exiting the process.
Never fakeExit(int code) => throw FakeExit(code);
