# Floating palette appearance

Command Palette and Clipboard History use `PluginPaletteSurface` from PluginKit. Clipboard History's action and queue companion palettes use the same surface. The menu-bar panel uses its own component theme.

## Ownership and rendering

- `PluginPaletteSurface` owns the shared floating-panel background. `PluginPaletteColors.selectedText` requires host 1.3.1; plugins using it must declare that minimum host version.
- On macOS 26 and later, the background bridges AppKit's `NSGlassEffectView` into SwiftUI with regular style. Hosted content remains outside the background so drag handles, native input, and view identity are preserved.
- There is one glass surface per panel, with no custom tint, opacity overlay, interactive glass, polling, private preference keys, or additional setting. Native glass owns the macOS 27 appearance control and live system updates. Layout and input content remain outside the background branch, preserving their identity when accessibility settings change.
- Reduce Transparency selects an opaque semantic background. macOS 14 and 15 use native material. Increase Contrast strengthens panel, selected-row, control, and image-preview boundaries. Selection text preserves the system's preferred foreground when it meets 4.5:1 contrast against the opaque selection background; otherwise it uses black or white. This also protects yellow accents, selected subtitles, and shortcut labels. Colors resolve again for the current appearance.
- Command Palette clips its backdrop to the visible rounded silhouette and applies one shared content shadow in both Settings and standalone presentations. The standalone panel uses a plain AppKit hosting container, disables automatic SwiftUI safe-area/sizing behavior, and has no second window shadow around its transparent padding. Clipboard keeps its existing hosting and native shadow.
- The host retains Command Palette routing, focus restoration, drag/snap coordination, and placement. Clipboard History retains its panel lifetime, explicit drag handle, native resizing, per-display placement, search model, previews, and action routing. Glass never tints captured previews or changes clipboard payloads.

Apple references: [custom SwiftUI glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [macOS 27 AppKit design updates](https://developer.apple.com/videos/play/wwdc2026/289/).

## Validation

Palette appearance and native interaction are checked manually. Automated screenshot capture, native pointer injection, and UI XCTest fixtures have been removed from the routine suite. Keep logic coverage in the command/search models, action executor, and clipboard controllers; see the [core test scope](../testing/core-tests.md).

For changes to this surface, exercise only the affected paths:

- Open the palette, type a query with ordinary text and IME composition, execute or cancel, and reopen.
- Check focus, dragging, resizing, and display placement when those behaviors change.
- Review light/dark appearance, Reduce Transparency, and Increase Contrast when changing material or colors. Use representative backgrounds and content rather than a screenshot matrix.
- For performance work, compare the same workload on equivalent builds and record the OS, settings, and observations. Avoid fixed wall-clock thresholds in XCTest.

Attach a representative screenshot or short recording to the review. Use `make ci` before pushing shared PluginKit changes; compile-time compatibility does not replace native acceptance on affected macOS versions.
