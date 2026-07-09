# ADR-047 Research Appendix — Embedding Assets in Dart AOT Binaries

Verified 2026-07-07 (Dart SDK 3.12.x era) via dart.dev docs, the dart-lang/sdk issue tracker, pub.dev, and primary-source reads of ecosystem tools. Summary of the evidence behind ADR-047's options analysis.

## 1. Dart SDK status: no shipping embed path

- `dart compile exe` output is machine code + a small runtime, nothing else; the docs contain no asset/resource language, and the command **fails if build hooks are present**. Flags 3.7→3.12 gained cross-compilation (`--target-os`/`--target-arch`) only — nothing asset-related. — https://dart.dev/tools/dart-compile
- Build hooks (`hook/build.dart`, `package:hooks`) stabilized in Dart 3.10, but the SDK consumes **`CodeAsset` only** (native dynamic libraries via `@Native`/`dart:ffi`). — https://dart.dev/tools/hooks
- `package:data_assets` is v0.20.0 under the **labs.dart.dev** publisher, explicitly experimental with high breaking-change expectations. — https://pub.dev/packages/data_assets
- The data-assets tracker shows the `dart:asset` runtime lookup API, standalone-Dart support, and in-executable storage all **not done**; only a Flutter experiment exists (SDK-team statement updated 2026-05). — https://github.com/dart-lang/sdk/issues/56217, https://github.com/dart-lang/sdk/issues/54003
- Even the target model is sidecar: `dart build cli` outputs `bundle/{bin,lib}/` — a **directory**, never a single file. — https://dart.dev/tools/dart-build
- The direct feature request ("embed resource files into compiled executables") has been open since 2019 with no movement since early 2024. — https://github.com/dart-lang/sdk/issues/39576, https://github.com/dart-lang/sdk/issues/55195
- `dart:core`'s `Resource` class was removed (deprecated 2015, sdk#24499); `package:resource` is **discontinued** on pub.dev — its banner cites AOT compilation as the reason. — https://pub.dev/packages/resource

## 2. Self-appending a blob to the executable: confirmed hack

- The mechanism is real — `dart compile exe` itself works by appending the AOT snapshot to the runtime (`writeAppendedMachOExecutable` etc. in SDK source) — but it is an internal implementation detail with **no public contract** for user data.
- Appending bytes to a signed Mach-O invalidates the code signature and fails notarization; Dart's executable format has historically fought `codesign` already. — https://developer.apple.com/library/archive/technotes/tn2206/_index.html, https://github.com/dart-lang/sdk/issues/39106, https://github.com/dart-lang/sdk/issues/49275
- No Dart ecosystem package implements the pattern. Ruled out.

## 3. Ecosystem survey: data-as-code codegen is the standard

- **very_good_cli** (verified from source): templates ship as checked-in generated `*_bundle.dart` files (`// GENERATED CODE - DO NOT MODIFY BY HAND`) containing `MasonBundle.fromJson({...})` literals with per-file base64 `data` entries; `mason bundle -t dart` is the supported generator. — https://github.com/VeryGoodOpenSource/very_good_cli (`lib/src/commands/create/templates/`), https://docs.brickhub.dev/mason-bundle/
- **dcli** (`dcli pack`, verified from docs): scans `resource/`, generates one `PackedResource` class per file (base64 content + checksum) plus a `ResourceRegistry` map; runtime API is `ResourceRegistry.resources['path'].unpack(localPath)` — decode-and-materialize-to-disk, the same shape as DartClaw's `WorkflowMaterializer`. — https://dcli.onepub.dev/dcli-tools-1/dcli-pack, https://dcli.onepub.dev/dcli-api/assets
- **`package:embed`** (actively maintained, ~May 2026): annotation + build_runner generator (`@EmbedStr`, `@EmbedBinary`, `@EmbedLiteral`) — the off-the-shelf equivalent of the bespoke pattern. — https://pub.dev/packages/embed
- dart_frog / serverpod moved to `dart build cli` (bundle-directory model — different distribution goal); melos / fvm distribute via `pub global activate` and carry no asset payload. Nothing in the ecosystem embeds via any mechanism other than generated source.

## Bottom line

As of mid-2026 there is no officially supported way to place data inside a `dart compile exe` binary, no near-term timeline, and the official direction (data assets) is sidecar-based regardless. The community-converged, contract-safe technique is build-time codegen of asset content into Dart source — which is what ADR-047 adopts.
