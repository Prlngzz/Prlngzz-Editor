# Windows build notes

The Windows x64 workflow is triggered automatically by pushes to `codex/**` or `development`, and can also be started manually with `workflow_dispatch`.


Current source baseline: v0.3.49. The workflow verifies formatting, tests, Clippy, and the Windows x64 executable before publishing artifacts.
