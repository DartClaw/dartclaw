// Clients cannot choose host credentials, routing or wire framing. Both
// mediated surfaces use these sets so their boundary cannot drift.
const droppedRequestHeaders = {
  'authorization',
  // HttpClient negotiates gzip itself; forwarding br/zstd would leave encoded bytes it cannot decompress.
  'accept-encoding',
  'content-encoding',
  'x-api-key',
  'openai-api-key',
  'api-key',
  'proxy-authorization',
  'cookie',
  // The account the credential belongs to: the host sets it from the token it
  // presents, and when that token carries none the container's own value
  // would otherwise be the one the backend read.
  'chatgpt-account-id',
  'host',
  'connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'te',
  'trailer',
  'content-length',
  'forwarded',
  'x-forwarded-host',
  'x-forwarded-for',
  'x-forwarded-proto',
};

/// Upstream response headers that must never be written back down the pipe.
///
/// The pipe is the only channel that enters a `network:none` container, so a
/// credential-bearing header an upstream, intermediary, or error page
/// reflected back would be handed straight into the boundary the rest of this
/// adapter exists to keep it out of. Dropped whether or not any known
/// upstream reflects one.
const droppedResponseHeaders = {
  'authorization',
  'x-api-key',
  'proxy-authenticate',
  // The client decoded the body on the way in (`autoUncompress`), so keeping
  // the encoding headers would describe bytes that no longer exist.
  'content-encoding',
  'content-md5',
  'connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'te',
  'trailer',
  'content-length',
  'set-cookie',
};
