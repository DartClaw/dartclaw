FROM dartclaw-agent:latest
USER root
COPY --from=dart:3.14.0-sdk /usr/lib/dart /usr/lib/dart
# Login shells reset PATH; expose the SDK in their standard search path too.
RUN ln -s /usr/lib/dart/bin/dart /usr/local/bin/dart
# Dart initializes ~/.dart-tool even when analytics is suppressed.
ENV DART_SDK=/usr/lib/dart \
    PATH="/usr/lib/dart/bin:${PATH}" \
    PUB_CACHE=/tmp/pub-cache \
    HOME=/tmp
USER dartclaw
