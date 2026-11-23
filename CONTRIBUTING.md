# Contributing to SnipBar

Thank you for your interest in contributing to **SnipBar**! This document outlines the development setup, architectural invariants, and pull request workflow.

## Prerequisites

- **macOS 14.0 (Sonoma)** or newer
- **Xcode 16+** (with Swift 5.10+)
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`)

## Local Development Setup

```bash
git clone https://github.com/rawat-divyanshu/SnipBar-macOS.git
cd SnipBar-macOS

# Run unit tests via SwiftPM
swift test --parallel

# Generate the Xcode project (ignored by git; project.yml is the source of truth)
xcodegen generate
open SnipBar.xcodeproj
```

Do not commit `SnipBar.xcodeproj`. Any build setting, target, or Info.plist change must be made in `project.yml` (and mirrored in `Package.swift` / `Config/Info.plist` when applicable).

## Architecture & Privacy Invariants

Please preserve these core design principles in all changes:

1. **Zero External Dependencies**: SnipBar relies exclusively on native Apple frameworks (`AppKit`, `SwiftUI`, `SwiftData`, `LocalAuthentication`, `ServiceManagement`, `Carbon`, `ApplicationServices`). Avoid introducing third-party dependencies without prior discussion in an issue.
2. **Ad-Hoc Local Signing (`-`)**: Keep `CODE_SIGN_IDENTITY: "-"` and `Config/SnipBar.entitlements` free of entitlements that require Apple Developer provisioning profiles (such as Keychain access groups).
3. **Zero Telemetry & Local-Only Storage**: Never add analytics, crash uploaders, or outbound network requests. Maintain `0700` permissions on `~/Library/Application Support/SnipBar/` and `0600` on `clipboard-history.json`.
4. **Secret Protection**:
   - Never index `SnippetRecord.content` in search when `isSecret == true`.
   - Always mark secret clipboard writes with `.currentHostOnly`, `org.nspasteboard.ConcealedType`, and `TransientType`.
   - Never capture concealed, transient, auto-generated, or password-manager pasteboard items in `ClipboardHistoryStore`.
   - Keep secrets unchecked by default in `.snipbar.json` exports.
5. **Minimal Permissions**: Never introduce global keyboard event monitors that trigger macOS Input Monitoring prompts. Only prompt for Accessibility when Auto-Paste is explicitly requested or enabled.
6. **Keep `Package.swift` and `project.yml` in Sync**: New files under `Sources/SnipBar` and `Tests/SnipBarTests` are picked up automatically, but any new Apple framework linkage must be added to `Package.swift` as well.

## Code Style & Testing

- Follow standard Swift API Design Guidelines and `.editorconfig` (4-space indentation, LF line endings).
- Keep `@MainActor` isolation explicit for AppKit/SwiftUI controllers and stores.
- Add or update XCTest coverage in `Tests/SnipBarTests/` for business logic, search ranking, clipboard ring behavior, and export/import changes.

Before opening a pull request, verify all checks pass locally:

```bash
swift test --parallel
swift build -c release
./scripts/build-release.sh
```

## Pull Request Process

1. Fork the repository and create a descriptive branch (e.g., `feat/custom-hotkey` or `fix/bezel-focus`).
2. Keep commits focused and well-scoped.
3. Update `README.md` and `CHANGELOG.md` if your change adds or modifies user-facing features or shortcuts.
4. Open a Pull Request using the repository's PR template and ensure GitHub Actions CI passes.

## Publishing a Release (Maintainers)

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml` and `Config/Info.plist`.
2. Add the new version section to `CHANGELOG.md`.
3. Tag and push the release commit (e.g., `git tag v1.0.0 && git push origin v1.0.0`).
4. `.github/workflows/release.yml` automatically runs tests, builds `SnipBar.app`, generates a `.sha256` checksum, and publishes the GitHub Release.
