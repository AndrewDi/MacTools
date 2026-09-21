# Panel layout editing validation

Start with the smallest relevant XCTest method or class. Reuse existing coverage and add only missing core behavior or a concrete regression.

| Area | Existing coverage |
| --- | --- |
| Layout persistence and migration | `MenuBarPanelStoreTests`, `PluginOrderingStoreTests`, `PreferencesBackupTests` |
| Independent placements, moves, removal, and Undo | `PanelLayoutEditorTests`, `PanelLayoutEditingSessionTests` |
| Selected-panel removal, dismissal, and resizing | `MenuBarPanelPresenterTests` |
| Grid placement and viewport mounting | `ComponentPanelLayoutTests`, `MenuBarPanelLayoutTests` |
| Feedback coalescing | `PanelLayoutToolbarTests` with explicit timestamps |

Check cosmetic changes visually. Avoid exact padding/color assertions, menu-count checks, captures without review, and repeated native click sequences for behavior already covered by model tests.

## Native drag fixture

For native drag routing or hit-testing changes, select the affected scenario:

```bash
python3 scripts/e2e/run_panel_layout_fixture.py --surface cross-panels
```

Run `--help` for the current scenario list. Use `make panel-layout-ui-tests` when a shared change warrants all scenarios. The fixture requires a logged-in macOS desktop and the repository's Xcode toolchain; it is opt-in and excluded from `make ci` and GitHub Build.

The runner compiles the production editor, toolbar, grid, drag session/source, and scroller into a temporary application with synthetic host/theme interfaces. It drives native AppKit events to check affected combinations of tab ordering, mixed widget/row layouts, cross-panel transfer, drag cancellation, Undo, and Done in left-to-right and right-to-left layouts.

Each scenario has a separate process and watchdog. Compilation and execution are bounded, temporary files are removed, and failures produce a nonzero exit. The fixture does not load installed plugins, use personal preferences, replace the Debug app, or post global pointer events.

The synthetic host verifies interaction; XCTest covers real host persistence, placement isolation, drag invalidation, insertion boundaries, and layout stability. Keep native drag acceptance in the standalone application: nested application loops or async event pumping inside XCTest can hang or miss drop completion.

## Physical acceptance

When the change affects these paths, check physical mouse/trackpad dragging, drag lock, dragging outside the app, sustained edge scrolling, keyboard navigation, VoiceOver, and Reduce Motion on the relevant macOS versions. Synthetic pointer events do not establish hardware or accessibility behavior. Record which scenarios were exercised and any remaining gaps in the PR.
