# Prlngzz Editor

Prlngzz Editor is a Windows-first Rust/egui desktop application for managing local Roblox asset-cache customizations and JSON replacement profiles, with Roblox RIVALS as its primary workspace.

This repository is being initialized from the source projects supplied for the Prlngzz Editor development brief. Development work is kept on a separate branch; the default `main` branch is the clean repository baseline.

## Safety

The application is intended for local cache customization only. It must not intercept HTTPS traffic, install certificates, collect Roblox passwords or session cookies, extract tokens, inject DLLs, manipulate process memory, bypass anti-cheat systems, or automate gameplay.

## Status

Initial repository scaffold. The application source and Windows CI pipeline are being added on a dedicated development branch. Do not treat this repository as a completed release until the CI build, tests, and Windows executable have been verified.