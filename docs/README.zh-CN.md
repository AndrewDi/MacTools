# 文档

[English](README.md) · **简体中文**

安装与功能概览见[中文 README](../README.zh-CN.md)或[英文 README](../README.md)。部分详细指南目前仅提供英文。

## 功能指南

| 主题 | 指南 |
| --- | --- |
| 操作、工作流与自动规则 | [操作与自动化](actions-automation.md) |
| 页面跳转与外部运行链接 | [URL API](url-scheme.md) |
| 命令行安装 | [Nightly CLI](testing/cli-nightly-distribution.md) |
| 本地 AI Agent 集成 | [CLI 使用指南](cli/agent-usage.md) |
| 截图、文字识别、滚动截图与录屏 | [截图](plugins/screenshot.md) |
| 剪贴板备份与恢复 | [加密备份](plugins/clipboard-backup.md) |
| 窗口导航与排列 | [窗口切换](plugins/window-switcher.md) · [窗口布局](plugins/window-layouts.md) |
| 键盘、鼠标与手势映射 | [输入映射](plugins/input-remapping.md) |
| 系统设置与配置方案 | [Mac 设置](plugins/mac-settings.md) |
| 菜单栏自定义 | [隐藏菜单栏图标](plugins/menu-bar-hidden.md) · [自定义图标](plugins/menu-bar-icons.md) |
| 音频控制 | [应用音量](plugins/app-volume.md) · [显示器音量](plugins/display-volume.md) |
| 监控 | [设备电量](plugins/device-battery.md) · [Duo 状态](plugins/duo-status.md) · [AI 用量](plugins/ai-usage.md) |
| Siri | [使用与限制](plugins/siri.md) |

## 开发

- [贡献指南](../CONTRIBUTING.zh-CN.md) / [English](../CONTRIBUTING.md)：环境、构建、测试与贡献流程。
- [本地原生插件](plugins/local-native-plugins.md)：开发与调试插件。
- [面板组件](plugins/panel-items.md)：声明自定义面板中的组件与控件。
- [插件目录](plugins/plugin-catalog.md)：插件发现与分发。
- [操作与自动化验证](testing/actions-automation-e2e.md)：原生端到端检查。

详细设计见[规格文档](superpowers/specs/)与[实施计划](superpowers/plans/)。它们保留设计过程，当前行为应以功能指南为准。
