# Panel items

PluginKit 7 replaces the primary-panel and component-panel protocols with
`MacToolsPlugin.panelItems`. A plugin may contribute multiple rows and widgets,
including multiple items of the same kind. The host owns the supported renderers,
grid, scrolling, editing, and panel windows.

## Declaring items

```swift
var panelItems: [PluginPanelItem] {
    [
        .row(
            id: "control",
            title: "Quick Control",
            initialPlacement: .featurePanel,
            descriptor: controlDescriptor,
            state: controlState,
            action: { [weak self] in self?.handleControl($0) }
        ),
        .widget(
            id: "overview",
            title: "Overview",
            initialPlacement: .dashboard,
            descriptor: overviewDescriptor,
            state: overviewState
        ) { [model] context in
            OverviewView(model: model, context: context)
        }
        .onVisibilityChange { [weak self] visible in
            self?.setOverviewPresented(visible)
        },
        .widget(
            id: "history",
            title: "History",
            descriptor: historyDescriptor,
            state: historyState
        ) { [model] context in
            HistoryView(model: model, context: context)
        }
    ]
}
```

Omitted titles, descriptions, and icons inherit plugin metadata. Give distinct
titles to multiple items so users can identify them in the library. Item IDs are
plugin-local, case-sensitive ASCII identifiers containing letters, numbers,
periods, underscores, or hyphens, with a maximum of 128 bytes. The host accepts
up to 256 definitions per plugin. Keep IDs and renderer kinds stable; do not
derive the catalog from transient records such as processes or calendar events.

`initialPlacement` is an optional, one-time suggestion. `.dashboard` and
`.featurePanel` refer to stable built-in panel identities, even after users move
or rename their tabs. Omitting it makes the item library-only. Moving or deleting
an item overrides the suggestion permanently until an explicit layout reset.
New item IDs in plugin upgrades are initialized once. Changing the default for
an existing ID does not rearrange user layouts.

The manifest declares allowed renderer kinds, not individual item IDs:

```json
"pluginKitVersion": 7,
"capabilities": {
  "panelItems": ["row", "widget"],
  "settings": "form"
}
```

Use an empty `panelItems` array for plugins without panel content. Runtime items
must use a declared kind. Invalid or duplicate IDs do not replace a valid catalog
silently. Installed packages from older PluginKit versions remain on disk and
must be updated before the host loads their code.

## Identity and state

An item definition is identified by `(pluginID, itemID)`. Each user-added placement
has a separate UUID. Copying creates a new UUID; moving preserves it. Copies share
the plugin and its business model, while host expansion, detail anchors, and
other presentation state use placement identity. Adding a view does not activate
another plugin instance or duplicate its background services.

Definitions are lightweight snapshots. After `onStateChange`, the host reads only
the changed plugin's items. State, localized labels, and widget dimensions may
change without changing identity. Getters and view factories must read existing
snapshots, not perform synchronous scans, hardware queries, or network requests.

`state.isAvailable` describes whether the view can currently be rendered, not a
user preference. Unavailable views retain their saved placements. Expansion and
navigation selection belong to each host placement; do not publish expansion in
the row state. Every row starts collapsed, and plugins should initialize their
detail-demand flag to `false`. Expansion is not persisted across app launches.
Unavailable rows, and disabled rows without detail content, lose
their expansion and navigation state. The host sends a collapsed action when the
last expanded copy is cleared; plugins must not independently reset expansion
while reading their state. Business actions remain shared through the item's
action handler.

The host localizes inherited default descriptions when the app language changes.
Plugins remain responsible for localizing explicit item descriptions, dynamic
subtitles, and errors. Library previews render the view itself without additional
title labels; item names remain available for library search, tooltips, and
accessibility. The library preserves plugin order and previews widgets before
rows, preserving declaration order within each renderer. Adding and removing
placements belong to panel editing, not command-palette commands.

For content-driven height, call `context.reportContentHeight(height)` from the
widget's intrinsic-content measurement, before applying the allocated host frame.
The host rounds valid heights to its grid and coalesces layout-only updates. Each
placement keeps its own measured height; the descriptor's span remains the default
for unmeasured placements and previews. Moving retains the measurement, removing
or discarding the widget session releases it, and the library measures previews
separately without changing live placements. Do not
write a placement's measured height into shared plugin state or call
`onStateChange` just to resize a widget.

The host lazily constructs nearby widgets and caches content per placement and
plugin revision. It updates routing closures independently of cached content.
SwiftUI local state remains mount-scoped; caching an `AnyView` does not preserve
arbitrary `@State` after viewport unmounting. Keep business data in the plugin's
model and explicitly retain any necessary per-placement state.

## Visibility and details

`onVisibilityChange` is aggregated across placements in the presented panel.
The first consumer receives `true` and the last receives `false`. Switching between
panels containing the same item does not restart its work. Scrolling, lazy view
mounting, and library previews do not deliver these notifications. Handlers may
request a state update or close the panel synchronously.

Widget context provides plugin and item IDs, an optional placement ID, dismissal,
and detail presentation. A missing placement ID identifies a preview. Preview
factories must be free of side effects and must not start polling or mutate shared
settings. Provide the widget's optional `detail` factory and call
`context.presentDetail(detailID)` to open a host-owned detail surface anchored to
the requesting placement.

## Host migration

Layout version 3 stores explicit ordered placements and initialized item keys.
The host converts old assignments, copies, removals, surface orders, and visibility
together. References to unavailable plugins remain in the layout. Old shared
preferences without renderer information retain a small migration seed until
capabilities are available; they do not invent a second view for every plugin.
Backup import uses the same conversion. Unknown or corrupt layout payloads are
preserved until an explicit reset or import.

Plugin management order is independent of panel placement. Removing a panel
preserves its placements in the first visible remaining panel, including entries
whose plugins are temporarily unavailable.
