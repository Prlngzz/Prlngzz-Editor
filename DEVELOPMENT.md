# Development hand-off

The Prlngzz Editor source snapshot is provided as `Prlngzz-Editor-source.zip` in the current ChatGPT conversation.

## Add the source to this repository

1. Download the ZIP from the ChatGPT conversation.
2. Open this repository on GitHub and switch to the `development` branch.
3. Use **Add file → Upload files** and upload the ZIP to the repository root with the exact name `Prlngzz-Editor-source.zip`.
4. Commit the upload to `development`.

The Windows x64 workflow at `.github/workflows/windows-x64.yml` extracts that archive on a Windows runner and then runs formatting, tests, Clippy, the release build, and executable/PE architecture checks. It uploads `Prlngzz-Editor-Windows-x64.exe` as a workflow artifact. An `editor-v*` tag publishes a GitHub Release.

## Local source layout

The ZIP contains a `Prlngzz-Editor/` directory with `Cargo.toml`, `Cargo.lock`, `src/`, `assets/`, `packs/`, and `THIRD_PARTY_NOTICES.md`. For local development, extract that directory and open it as the Rust project. Do not commit build output under `target/`.

## Verification status

The archive has been checked for ZIP integrity. Static checks confirmed that `Cargo.toml` is valid TOML and names the package `prlngzz-editor` version `0.1.0`, all 22 declared Rust modules have matching source files, and all seven bundled JSON files parse successfully.

Rust compilation, Rust tests, Clippy, Windows x64 executable startup, and in-game cache behavior have not yet been verified. A successful CI run is required before calling this a working release.

## Safety and compatibility

Keep the application local-cache-only. Do not add HTTPS interception, certificate installation, Roblox credential/cookie handling, token extraction, process injection, memory manipulation, anti-cheat bypasses, or gameplay automation. Preserve unknown Fleasion JSON fields and issue explicit warnings for selectors the cache engine cannot apply.
