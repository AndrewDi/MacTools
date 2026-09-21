# Documentation

**English** · [简体中文](README.zh-CN.md)

Start with the [English README](../README.md) or [Chinese README](../README.zh-CN.md) for installation and the product overview.

## Feature guides

| Topic | Guide |
| --- | --- |
| Actions, workflows, and automatic rules | [Actions & automation](actions-automation.md) |
| App navigation and external Run Links | [URL API](url-scheme.md) |
| Command-line installation | [Nightly CLI](testing/cli-nightly-distribution.md) |
| Local AI-agent integration | [CLI agent usage](cli/agent-usage.md) |
| Screenshots, OCR, scrolling capture, and recording | [Screenshot](plugins/screenshot.md) |
| Clipboard backup and restore | [Encrypted clipboard backup](plugins/clipboard-backup.md) |
| Window navigation and arrangement | [Window Switcher](plugins/window-switcher.md) · [Window Layouts](plugins/window-layouts.md) |
| Keyboard, mouse, and gesture mappings | [Input remapping](plugins/input-remapping.md) |
| macOS settings and reusable profiles | [Mac Settings](plugins/mac-settings.md) |
| Menu bar customization | [Hide Menu Bar Icons](plugins/menu-bar-hidden.md) · [Custom icons](plugins/menu-bar-icons.md) |
| Audio controls | [App Volume](plugins/app-volume.md) · [Display Volume](plugins/display-volume.md) |
| Monitoring | [Device Battery](plugins/device-battery.md) · [Duo Status](plugins/duo-status.md) · [AI Usage](plugins/ai-usage.md) |
| Siri | [Usage and limitations](plugins/siri.md) |

## Development

- [Contributing](../CONTRIBUTING.md) / [Chinese](../CONTRIBUTING.zh-CN.md): environment, build, test, and contribution workflow.
- [Local native plugins](plugins/local-native-plugins.md): develop and debug a plugin.
- [Panel items](plugins/panel-items.md): declare widgets and controls for custom panels.
- [Plugin catalog](plugins/plugin-catalog.md): package discovery and distribution.
- [Actions and automation verification](testing/actions-automation-e2e.md): native end-to-end checks.

Detailed design decisions live in [specifications](superpowers/specs/) and [implementation plans](superpowers/plans/). They record design history and are not a substitute for current feature guides.
