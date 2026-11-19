# Development hand-off

The current source snapshot is supplied separately as `Prlngzz-Editor-source.zip` in the ChatGPT conversation. It contains the Rust project, bundled JSON presets, font licensing notice, native profile implementation, and Windows CI workflow.

## Source import

Before running the Windows build workflow, extract the source archive into the repository root so that `Cargo.toml`, `Cargo.lock`, `src/`, `assets/`, `packs/`, and `.github/workflows/windows.yml` are at the repository root. Preserve the `THIRD_PARTY_NOTICES.md` file. Do not commit build output under `target/`.

## Verification

The archive has been checked for ZIP integrity, and static checks confirmed:

- `Cargo.toml` is valid TOML and names the package `prlngzz-editor` version `0.1.0`.
- All 22 declared Rust modules have matching source files.
- All seven bundled JSON files parse successfully.

Rust compilation, Rust tests, Clippy, Windows x64 executable startup, and in-game cache behavior have not yet been verified. A successful CI run is required before calling this a working release.

## Safety and compatibility

Keep the application local-cache-only. Do not add HTTPS interception, certificate installation, Roblox credential/cookie handling, token extraction, process injection, memory manipulation, anti-cheat bypasses, or gameplay automation. Preserve unknown Fleasion JSON fields and issue explicit warnings for selectors the cache engine cannot apply.
