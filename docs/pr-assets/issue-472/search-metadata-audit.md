# Capability search metadata audit for issue 472

Baseline: `1183819756c3aa6c3e9f5ea7b95531c57bfdf788`, after the search implementation and integration of current main. The audit reviewed all 64 source plugin manifests against current implementation, settings, action declarations, and feature documentation. It found 284 missing owner/query pairs across 51 plugins (278 distinct queries). Every selected pair failed to discover its owner before the metadata changes and succeeds afterward using the production website search helper. This is a focused capability audit, not exhaustive coverage of every natural-language query or every supported language.

Only English `discovery.keywords` and simplified-Chinese `discovery.localizedSynonyms` are extended. Existing translations, use cases, action providers, runtime requirements, and release versions are preserved. Search terms describe a plugin capability; they do not create executable static actions. The 135 existing static actions remain unchanged.

## Before and after

| Query | Before | After |
| --- | --- | --- |
| `tiptap` / `tip tap` | No results | Trackpad Gestures; Input Remapping |
| `smooth scrolling` / `平滑滚动` | No results | Mouse Enhancer |
| `launch agents` | No results | Launch Control |
| `RPM` | No results | Fan Control |
| `lunar calendar` | No results | Calendar |
| `AirPods` | No Device Battery result | Device Battery |
| `CPU` | No System Status result | System Status |

![TipTap search before and after](tiptap-before-after.png)

The TipTap capture uses the same local website, appearance, viewport, and search implementation. The before state is the baseline above; the after state contains this metadata follow-up. These screenshots show discovery and navigation, not execution or hardware validation.

## Accepted discovery additions

The source link identifies an implementation entry point or feature documentation. Related implementation and localized settings were also checked; a single entry point does not enumerate every listed capability.

| Plugin | English keywords added | Simplified-Chinese aliases added | Source evidence |
| --- | --- | --- | --- |
| Action Grid | nested folders | 多级网格 | [ActionGridStore.swift:88](../../../Plugins/ActionGrid/Sources/ActionGridStore.swift#L88) |
| Activity Stats | screen time; keystrokes; mouse clicks; scrolls; AI work time | 屏幕时间; 按键统计; 点击统计; 滚动统计; AI 工作时长 | [ActivityBarComponentView.swift:332](../../../Plugins/ActivityBar/Sources/ActivityBarComponentView.swift#L332) |
| AI Assistant | prompt template; custom prompts; clipboard text | 提示词模板; 自定义模板; 剪贴板文本 | [AIAssistantPromptEditor.swift:41](../../../Plugins/AIAssistant/Sources/Settings/AIAssistantPromptEditor.swift#L41) |
| AI Usage | remaining quota; quota pace | 剩余额度; 额度消耗 | [AIUsagePresentation.swift:36](../../../Plugins/AIUsage/Sources/AIUsagePresentation.swift#L36) |
| App Hotkeys | hide app | 隐藏应用 | [AppHotkeyPlugin.swift:38](../../../Plugins/AppHotkey/Sources/AppHotkeyPlugin.swift#L38) |
| App Volume | per-app volume | 应用静音 | [AppVolumePlugin.swift:756](../../../Plugins/AppVolume/Sources/AppVolumePlugin.swift#L756) |
| Apple Shortcuts | run shortcuts; shortcut folders | 运行快捷指令; 快捷指令文件夹 | [AppleShortcutsSettingsView.swift:210](../../../Plugins/AppleShortcuts/Sources/AppleShortcutsSettingsView.swift#L210) |
| Auto-hide Dock | show dock | 显示程序坞 | [AutoHideDockPlugin.swift:204](../../../Plugins/AutoHideDock/Sources/AutoHideDockPlugin.swift#L204) |
| Auto-hide Menu Bar | menu bar visibility; show menu bar | 菜单栏显示; 显示菜单栏 | [AutoHideMenuBarPlugin.swift:153](../../../Plugins/AutoHideMenuBar/Sources/AutoHideMenuBarPlugin.swift#L153) |
| Auto Input | input source HUD; input source shortcuts | 输入法提示; 输入法快捷键 | [AutoInputPlugin.swift:339](../../../Plugins/AutoInput/Sources/AutoInputPlugin.swift#L339) |
| Calendar | lunar calendar; recent events | 农历; 近期日程 | [CalendarModels.swift:121](../../../Plugins/Calendar/Sources/CalendarModels.swift#L121) |
| Clipboard | keyword expansion; text expansion; clipboard backup | 关键词展开; 文本展开; 剪贴板备份 | [ClipboardSavedLibraryView.swift:146](../../../Plugins/ClipboardHistory/Sources/ClipboardSavedLibraryView.swift#L146) |
| Cloudflare R2 Upload | object storage; public link | 对象存储; 公开链接 | [R2UploadService.swift:162](../../../Plugins/CloudflareR2/Sources/R2UploadService.swift#L162) |
| Storage Explorer | treemap; space map | 空间图 | [StorageExplorerWorkspaceView.swift:129](../../../Plugins/StorageExplorer/Sources/StorageExplorerWorkspaceView.swift#L129) |
| Device Battery | AirPods; iPhone; iPad; Apple Watch; low battery notifications | 低电量通知 | [device-battery.md:8](../../../docs/plugins/device-battery.md#L8) |
| Disk Cleanup | app caches; browser caches; logs; diagnostic reports | 应用缓存; 浏览器缓存; 日志与诊断报告 | [DiskCleanRuleCatalogV2.swift:89](../../../Plugins/DiskClean/Sources/DiskCleanRuleCatalogV2.swift#L89) |
| Display Brightness | DDC/CI; software brightness | 软件亮度 | [DisplayBrightnessBackends.swift:154](../../../Plugins/DisplayBrightness/Sources/DisplayBrightnessBackends.swift#L154) |
| Display Resolution | HiDPI | — | [DisplayResolutionController.swift:153](../../../Plugins/DisplayResolution/Sources/DisplayResolutionController.swift#L153) |
| Display Sleep | turn off displays | 关闭显示器; 息屏 | [DisplaySleepPlugin.swift:189](../../../Plugins/DisplaySleep/Sources/DisplaySleepPlugin.swift#L189) |
| Display Volume | monitor volume; DDC/CI | 外接显示器音量; 音量快捷键; 跟随鼠标 | [DisplayVolumePlugin.swift:641](../../../Plugins/DisplayVolume/Sources/DisplayVolumePlugin.swift#L641) |
| Dock Lock | — | 固定程序坞 | [dock-lock.md:10](../../../docs/features/dock-lock.md#L10) |
| Duo Status | Wi-Fi signal; battery percentage; Bluetooth audio | Wi-Fi 信号; 电量百分比; 蓝牙音频 | [DuoStatusPlugin.swift:194](../../../Plugins/DuoStatus/Sources/DuoStatusPlugin.swift#L194) |
| Eject Disks | eject drives; external drive | 弹出磁盘; 移动硬盘 | [EjectDiskService.swift:129](../../../Plugins/EjectDisk/Sources/EjectDiskService.swift#L129) |
| Fan Control | RPM; full speed; fan presets | 风扇预设; 自定义转速 | [FanControlModels.swift:32](../../../Plugins/FanControl/Sources/FanControlModels.swift#L32) |
| Fix Damaged Apps | repair apps | 修复应用 | [FixDamagedAppPlugin.swift:326](../../../Plugins/FixDamagedApp/Sources/FixDamagedAppPlugin.swift#L326) |
| Homebrew Manager | install packages; uninstall packages; pin version | 安装软件包; 卸载软件包; 锁定版本 | [HomebrewController.swift:547](../../../Plugins/Homebrew/Sources/HomebrewController.swift#L547) |
| Custom Shortcuts: Keyboard, Trackpad, Mouse | TipTap; tip tap; trackpad gestures; scroll wheel; mouse side buttons; double-click; long press; single key | 触控板手势; 鼠标侧键; 滚轮; 双击; 长按; 单键 | [InputRemappingPlugin.swift:867](../../../Plugins/InputRemapping/Sources/InputRemappingPlugin.swift#L867) |
| IP Check | DNS leak test; WebRTC leak test; IPv6; speed test | DNS 泄漏测试; WebRTC 泄露测试; IPv6 地址 | [IPOverviewLeakTestService.swift:25](../../../Plugins/IPOverview/Sources/IPOverviewLeakTestService.swift#L25) |
| Keep Awake | prevent sleep; closed lid; keep screen sharing awake; keep remote control awake | 防止休眠; 屏幕共享保持唤醒; 远程控制保持唤醒 | [KeepAwakePlugin.swift:837](../../../Plugins/KeepAwake/Sources/KeepAwakePlugin.swift#L837) |
| Launch Items | launch agents; LaunchAgents; launch daemons; LaunchDaemons; background services | 后台服务 | [LaunchControlScanner.swift:221](../../../Plugins/LaunchControl/Sources/LaunchControlScanner.swift#L221) |
| Launchpad | app launcher; hot corner; app folders; fuzzy search | 应用启动器; 热区唤起; 应用文件夹; 模糊搜索 | [LaunchpadGridView.swift:151](../../../Plugins/Launchpad/Sources/LaunchpadGridView.swift#L151) |
| Lock Screen | — | 锁屏 | [LockScreenPlugin.swift:69](../../../Plugins/LockScreen/Sources/LockScreenPlugin.swift#L69) |
| Mac Settings | System Preferences; Finder settings; Dock settings; screenshot format; key repeat rate; three-finger drag | 系统设置; 访达设置; 程序坞设置; 截屏格式; 按键重复速度; 三指拖移 | [SystemSettingCatalog.swift:122](../../../Plugins/MacSettings/Sources/Catalog/SystemSettingCatalog.swift#L122) |
| Hide Menu Bar Icons | always hidden; menu bar layout | 永久隐藏; 菜单栏布局 | [MenuBarHiddenSettingsView.swift:60](../../../Plugins/MenuBarHidden/Sources/MenuBarHiddenSettingsView.swift#L60) |
| Microphone Mute | unmute microphone | 恢复麦克风 | [MicrophoneMutePlugin.swift:236](../../../Plugins/MicrophoneMute/Sources/MicrophoneMutePlugin.swift#L236) |
| Middle Click | three-finger tap; four-finger tap; five-finger tap | 中键点击; 三指轻点; 四指轻点; 五指轻点 | [MiddleClickPlugin.swift:249](../../../Plugins/MiddleClick/Sources/MiddleClickPlugin.swift#L249) |
| Mouse Enhancer | smooth scrolling; scroll speed; scroll step; reverse scrolling | 平滑滚动; 滚动速度; 滚动步长; 反转滚动 | [MouseEnhancerPlugin.swift:353](../../../Plugins/MouseEnhancer/Sources/MouseEnhancerPlugin.swift#L353) |
| Quit Apps | quit all apps | 退出全部应用 | [QuitAppsSelectionWindow.swift:36](../../../Plugins/QuitApps/Sources/QuitAppsSelectionWindow.swift#L36) |
| Right Click | new file; new folder; open in terminal; open with; copy path; copy file name | 在终端打开; 用应用打开; 复制路径; 复制文件名 | [RightClickMenuSettingsView.swift:50](../../../Plugins/RightClick/Sources/RightClickMenuSettingsView.swift#L50) |
| Saved Scripts | bash; zsh; script library | 脚本库 | [SavedScriptModels.swift:3](../../../Plugins/SavedScripts/Sources/SavedScriptModels.swift#L3) |
| Screenshot | blur; pixelate | 模糊; 马赛克 | [Overlay.swift:1205](../../../Plugins/Screenshot/Sources/Overlay.swift#L1205) |
| Sidecar | wired; cable | 有线连接; 仅有线 | [SidecarSettingsView.swift:727](../../../Plugins/Sidecar/Sources/SidecarSettingsView.swift#L727) |
| System Data | AI models; iOS backups; app data; containers & VMs; virtual machines; logs & diagnostics; developer tool data | AI 模型; iOS 设备备份; 应用数据; 容器与虚拟机; 日志与诊断; 开发工具数据 | [SystemDataCatalog.swift:80](../../../Plugins/SystemData/Sources/SystemDataCatalog.swift#L80) |
| System Status | CPU; GPU; memory; RAM; disk; battery; network; processes; temperature; battery health; memory pressure | 内存; 磁盘; 电量; 网络; 进程; 温度; 电池健康; 内存压力 | [SystemStatusModels.swift:4](../../../Plugins/SystemStatus/Sources/SystemStatusModels.swift#L4) |
| System Soft Restart | reopen apps; preserve Dock layout | 重启用户服务; 重新打开应用; 保留 Dock 布局 | [SystemSoftRestartPlugin.swift:200](../../../Plugins/SystemSoftRestart/Sources/SystemSoftRestartPlugin.swift#L200) |
| Trackpad Gestures | TipTap; tip tap; three-finger tap; double tap; touch and hold; physical click | 三指轻点; 双击; 长触; 按下点击 | [TrackpadGestureCatalog.swift:10](../../../Sources/MacToolsPluginKit/TrackpadGestureCatalog.swift#L10) |
| Translator | speak translation; OpenAI translation | 朗读译文; OpenAI 翻译 | [TranslatorPanelView.swift:211](../../../Plugins/Translator/Sources/Panel/TranslatorPanelView.swift#L211) |
| Window Layouts | custom layouts; modifier drag; centered window guides | 自定义布局; 修饰键拖移; 窗口居中参考线 | [WindowLayoutsPlugin.swift:509](../../../Plugins/WindowLayouts/Sources/WindowLayoutsPlugin.swift#L509) |
| Window Switcher | search windows; window preview; cycle windows; minimized windows | 搜索窗口; 窗口预览; 连续切换; 最小化窗口 | [WindowSwitcherOverlayController.swift:492](../../../Plugins/WindowSwitcher/Sources/WindowSwitcherOverlayController.swift#L492) |
| Xcode Cleanup | simulator caches; preview caches; dSYM | 模拟器缓存; 预览缓存 | [XcodeCleanRuleCatalog.swift:42](../../../Plugins/XcodeClean/Sources/XcodeCleanRuleCatalog.swift#L42) |
| zsh Config | alias; environment variable; PATH directory; .zprofile; .zshenv | 别名; 环境变量; PATH 路径 | [ZshConfigModels.swift:7](../../../Plugins/ZshConfig/Sources/ZshConfigModels.swift#L7) |

## Reviewed without additions

Dark Mode, Battery Charge Limit, Clear Clipboard, True Tone, Hide Active App on Dock Click, Empty Trash, Hide Notch, Night Shift, Clean Mode, Siri, Stage Manager, System Mute, Power Actions. Their core capability queries already match existing names, summaries, keywords, or static actions. Additional grammatical variants were not treated as automatic gaps.

## Capability limits and rejected candidates

- Display Resolution deduplicates modes by logical dimensions and retains the current refresh rate; its UI has no independent Hz selection. `refresh rate` / `刷新率` are excluded (`DisplayResolutionController.swift:145`; `DisplayResolutionPluginTests.swift:47`).
- Fan Control implements automatic, full-speed, and fixed-RPM presets. Temperature-based fan curves are not implemented and are excluded.
- Apple Shortcuts has runnable shortcuts and folders. Obsolete folder-sync resource strings do not establish a current sync feature and are excluded.
- Trackpad Gestures and Input Remapping expose shared TipTap gestures. Unsupported pinch, rotation, swipe, and force-click gestures are excluded. Input Remapping also supports single-key output (`InputRemappingEventTap.swift:453`).
- Mouse Enhancer implements smooth/reversed scrolling. Old middle-click compatibility strings are not used to claim that feature; current ownership belongs to the gesture plugins.
- System Data inventories and reveals locations; it does not clean them. Its VM coverage includes Docker Desktop `Data/vms`, OrbStack, and Apple Container, not arbitrary virtual-machine installations (`SystemDataCatalog.swift:277`).
- Device Battery supports paired/trusted iPhone and iPad readings, AirPods, and a paired Apple Watch reached through its iPhone (`DeviceBatteryMobileDeviceReader.swift:662,750`). Hardware compatibility and pairing requirements still apply.
- Keep Awake sharing/remote-control aliases describe keeping the Mac available, not providing screen sharing or remote control (`KeepAwakeUserActivityMaintainer.swift:67`).
- Launch Control inventories system agents/daemons and manages supported user agents. System jobs remain read-only; modern login-item management is not claimed.
- Cloudflare R2 public links require a configured public base URL.
- Xcode Clean finds archive data containing dSYMs; it does not provide a separate arbitrary dSYM scanner.
- Activity Bar AI work time counts active hook intervals and excludes waiting/ended intervals (`ActivityBarCodingSessionStore.swift:293`).
- Night Shift scheduling/temperature controls, Hide Notch wallpaper editing, and unsupported NAT-classification promises are excluded.

## Validation

- All 64 manifests pass semantic and complete-product-metadata validation.
- Website generator tests and generated-data freshness pass; static-action projection is byte-identical to baseline.
- All 284 accepted owner/query pairs pass through the production helper; protected files outside the planned write surfaces remain unchanged.
- Representative capability regressions and the complete website suite pass.
- Static build produces 203 pages with no errors, warnings, or hints.
- Chromium and WebKit verify representative English/Chinese metadata queries, two TipTap owners without invented actions, category filtering, language switching, and owner navigation. Existing action-search/disclosure/navigation/prerequisite checks also pass.
- Localization, changelog, and diff checks pass. Native app execution and hardware acceptance are outside this metadata-only verification.
