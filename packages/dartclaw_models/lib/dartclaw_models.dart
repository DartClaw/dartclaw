/// Data models for DartClaw sessions, messages, and memory.
///
/// Zero-dependency package containing the core data types shared across
/// all DartClaw packages:
/// - [Session] / [SessionType] -- agent conversation sessions
/// - [Message] -- chat messages with role and content
/// - [SessionKey] -- typed session identifier
/// - [MemoryChunk] / [MemorySearchResult] -- memory system types
library;

export 'src/models.dart'
    show Session, SessionType, Message, MemoryChunk, MemorySearchResult;
export 'src/session_key.dart' show SessionKey;
