import '../server.dart';

/// Writes one diagnostic line to the composing process's error sink.
typedef WriteLine = void Function(String line);

/// Terminates the composing process with [code].
///
/// Never returns, so a caller may use it as the tail of a fail-closed branch.
typedef ExitFn = Never Function(int code);

/// Post-construction hook over an assembled [DartclawServer].
///
/// Returns the server to use in place of the one supplied, so an implementation
/// may decorate or substitute it. Returning the argument unchanged is a no-op.
typedef ServerFactory = DartclawServer Function(DartclawServer server);
