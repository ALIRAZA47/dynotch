# Contributing to Dynotch

Thanks for your interest. Dynotch is a native macOS app (SwiftUI + AppKit, no
third-party dependencies). This guide covers how to build it and how changes get in.

## Requirements

- The macOS 26 SDK, which the Glass theme compiles against. The app itself runs on macOS 14 or later.
- Its Swift toolchain — either Xcode 26 or later, or its Command Line Tools (`xcode-select --install`).

## Build and run

```bash
./scripts/build.sh      # builds and signs build/Dynotch.app
open build/Dynotch.app
```

Run `./scripts/make-signing-identity.sh` once first. It creates a self-signed
"Dynotch Local Signing" certificate in a keychain of its own, with a password you choose,
so macOS keeps the app's permissions across rebuilds; `build.sh` asks for the password when
that keychain is locked. Without it the app is signed ad hoc and looks like a new app to
macOS after every build. Builds are signed with the hardened runtime; what the app may
reach is listed in `Support/Dynotch.entitlements`.

For a quick loop, `swift build` and `.build/debug/Dynotch` also work. Reviewing UI?
`Dynotch --snapshot <folder>` renders every notch state with sample data to PNGs.

## How changes get in

`main` is protected: no one pushes to it directly, and every change lands through a
pull request that the maintainer approves. So:

1. Branch off `main` (`git switch -c your-change`).
2. Make the change. Keep it focused — one topic per PR.
3. Push your branch and open a PR against `main`.
4. CI builds the app on every PR; keep it green.
5. A maintainer reviews. Once approved, it merges.

## Style

Match the code around you. A few conventions this codebase keeps:

- **No `@State`.** The macOS SDK ships the `@State` macro only with Xcode, and the app
  builds with the Command Line Tools, so use the `@ViewState` wrapper
  (`Sources/Dynotch/UI/ViewState.swift`) instead.
- Comments say *why*, not *what*. Keep them sparse and in the house voice.
- No new third-party dependencies without discussing it first.
- Prefer small, self-contained types; follow the existing file and folder layout.

## Reporting bugs and ideas

Open an issue with what you expected, what happened, your macOS version and Mac model.
For anything security-related, see [SECURITY.md](SECURITY.md) — please don't open a
public issue for it.
