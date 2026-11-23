## Summary

<!-- Briefly describe what this PR changes and why. -->

## Related Issue

<!-- Link any related issue, e.g. Closes #123 -->

## Testing Done

- [ ] `swift test --parallel` passes locally
- [ ] `swift build -c release` succeeds locally
- [ ] Verified in Xcode / `SnipBar.app` on macOS 14+ (if UI or AppKit behavior changed)

## Checklist

- [ ] Zero unnecessary external dependencies introduced
- [ ] `project.yml`, `Package.swift`, and `Config/Info.plist` remain in sync
- [ ] No generated `SnipBar.xcodeproj/`, `build/`, `dist/`, or `.snipbar.json` files committed
- [ ] Privacy & secret-handling invariants preserved (masked previews, `ConcealedType`/Handoff blocking, `0700`/`0600` permissions)
- [ ] `README.md` and `CHANGELOG.md` updated for user-facing changes
