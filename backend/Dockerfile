# Build the server to a native executable, then ship only that.
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o bin/server

# Runtime carries no Dart SDK and no source: a smaller image and nothing to
# read if anyone gets a shell in it.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/bin/server

# Symbols are mounted, not baked: they change with every app build, and an
# image rebuild per demo run would be absurd.
VOLUME /symbols
ENV SYMBOLS_DIR=/symbols
ENV DEDUPE_PATH=/state/dedupe.json
VOLUME /state

EXPOSE 8787
CMD ["/app/bin/server"]
