# 贡献指南

[English](CONTRIBUTING.md) · **简体中文**

欢迎修复问题、开发插件、完善翻译与文档，以及改进界面。MacTools 注重原生体验、轻量运行和低打扰；每个 PR 聚焦一个问题，并验证实际行为。

## 开始之前

先搜索[已有 Issue](https://github.com/mactools-app/MacTools/issues) 和 PR。新增插件、公共 PluginKit API 或较大的交互改动，请先用 Issue 说明用户需求、预期行为和取舍。提交信息与 PR 标题优先使用英文；也欢迎清晰的中文反馈。

### Issue 推荐格式

从[新建 Issue](https://github.com/mactools-app/MacTools/issues/new/choose) 选择 [Bug report（问题反馈）](https://github.com/mactools-app/MacTools/issues/new?template=bug_report.yml)或 [Feature or plugin request（功能或插件建议）](https://github.com/mactools-app/MacTools/issues/new?template=feature_request.yml)。模板统一使用英文，内容可以用中文或英文填写。

- **问题反馈：** 只需必填「遇到了什么问题」「当时在做什么」「MacTools 版本」三项。版本无法获取时填「未知」。系统／插件信息和截图均为选填，偶发问题不要求稳定复现。
- **功能建议：** 只需必填「你想完成什么」「希望怎样改进」两项。参考资料选填，不要求提供技术方案。

简单写几句话即可。标题尽量具体，每次反馈一个问题或想法，提交前搜索未关闭和已关闭的 Issue；已有相同问题时在原帖补充。附件请移除私人信息。使用咨询和一般交流请到 [Discussions 讨论区](https://github.com/mactools-app/MacTools/discussions)。

### 维护者的 Issue 处理流程

表单自动添加 `bug` 或 `enhancement`，后续处理保持简单：

- 确认范围及是否重复；文档工作使用 `documentation`，使用咨询引导到 Discussions。
- 只追问排查必需的信息。等待补充时使用 `question`，收到答复后移除。不要因选填项留空而拒绝有价值的反馈，也不要因长期未更新就自动关闭已确认的 Bug。
- 关联实现 PR 和验证结果。关闭时说明原因：`duplicate` 链接原问题，`wontfix` 解释取舍；修复则注明所在版本或尚待发布。开始处理时指定负责人，确定发布目标后再加入里程碑。

模板合并到默认分支后生效。普通用户的模板选择页隐藏空白入口，维护者及 API/CLI 提交仍可绕过。此流程参考 [LocalSend 的问题表单](https://github.com/localsend/localsend/blob/main/.github/ISSUE_TEMPLATE/bug_report.yml)和 [VS Code 的分类流程](https://github.com/microsoft/vscode/wiki/Issue-Tracking)。

## 构建与运行

需要 macOS、支持 Swift 6 的 Xcode 和 XcodeGen。应用最低支持 macOS 14，部分 API 需要更新版本；CI 环境见 [Build workflow](.github/workflows/build.yml)。

```bash
brew install xcodegen
make setup
```

在生成的 `LocalConfig.xcconfig` 中填写 `DEVELOPMENT_TEAM` 和稳定的 `BUNDLE_IDENTIFIER_PREFIX`，然后运行：

```bash
make run
```

该命令构建应用与插件、同步 Debug catalog，并安装 `~/Applications/MacTools Dev.app`。完整同步会把当前检出中不存在的插件移入可恢复的隔离目录；按插件筛选的同步保留其他插件。

| 命令 | 用途 |
| --- | --- |
| `make generate` | 生成插件 target 和 Xcode 项目；不要直接运行 `xcodegen generate`。 |
| `make build` | 编译应用及插件 target。 |
| `make sync-debug-plugins PLUGIN=calendar` | 先构建应用 target，再只同步指定 Debug 插件，不启动应用。 |
| `make build-plugin PLUGIN=calendar` | 验证独立插件包及 Debug catalog。 |

不要提交本地配置、凭证、生成的项目文件或构建产物。插件包配置与调试见[本地插件开发](docs/plugins/local-native-plugins.md)。

## 代码放在哪里

| 路径 | 职责 |
| --- | --- |
| `Sources/App/` | 菜单栏面板、设置、窗口与应用路由。 |
| `Sources/Core/` | 插件宿主、操作、权限、快捷键、存储与更新。 |
| `Sources/MacToolsPluginKit/` | 公共插件协议、描述式 UI 与运行时上下文。 |
| `Plugins/<PluginName>/` | `plugin.json`、`Sources/`、`Bundle/`、资源和相邻的 `Tests/`。 |
| `Tests/` | App/Core 共享逻辑测试。 |
| `docs/plugins/` | 功能约定与插件开发指南。 |

普通插件无需修改根 `project.yml`；必要的构建差异放在插件自己的 `project.yml`。Finder Sync 等 app extension 必须由宿主嵌入。

## 开发规范

遵循[插件开发规范](docs/plugins/development-guidelines.md)，并参考相邻实现。通用要求如下：

- **遵守宿主协议。** 实现 `MacToolsPlugin`，通过稳定的 `panelItems` 声明视图；manifest 的能力、操作策略、权限和最低宿主版本应与运行时一致。复用宿主操作与快捷键。
- **保持设计一致。** 优先使用描述式设置、宿主渲染器、`PluginSettingsTheme` 和 `PluginComponentTheme`。统一字体、间距、控件、焦点与错误状态；本地化用户文案并检查长文本。
- **支持可复用 widget。** 正确处理零个或多个实例、独立预览、视图回收及每个放置实例的独立展示状态。详见[面板组件](docs/plugins/panel-items.md)。
- **控制性能与能耗。** 使用缓存快照、事件驱动、有界异步任务和按可见性更新的展示层。面板隐藏时保留用户明确启用的监控，插件停用时释放其拥有的任务与资源。详见[性能要求](docs/plugins/development-guidelines.md#performance-and-energy)。
- **保留用户控制权。** 处理权限拒绝、取消、不支持的硬件和系统变化，保留已有确认、恢复路径及破坏性操作保护。

## 验证

覆盖核心结果和实际回归风险。优先复用现有测试；只有变更后的行为缺少有效保护时，才补充或调整聚焦的测试。重点覆盖主流程，以及本次改动涉及的数据丢失、权限、取消、兼容性等关键边界。

不按每个 PR 的测试数量或覆盖率百分比设门槛。不要增加仅复述实现、断言私有调用顺序，或检查固定文案、颜色、间距的测试。纯文档与外观微调通常通过 Review 和视觉检查验证，无需新增自动化测试。

运行最小相关测试类或方法。例如：

```bash
make test TEST_FILTER=ActionExecutorTests
```

将测试选择器替换为本次改动对应的测试；需要完整测试时再移除它。使用临时目录、测试数据和 fake service，避免访问真实用户数据或账号。仅在出现失败、共享协议变化或影响其他行为时扩大验证范围；相关检查通过后，仅在有新改动、失败或未覆盖风险时重复运行。

| 改动 | 验证范围 |
| --- | --- |
| 应用或插件行为 | 编译并运行相关现有测试；仅为缺失的核心行为或回归补测，必要时手动验证硬件与系统集成。 |
| UI 或 widget | 提供下述 UI 证据，检查受影响的交互；仅在状态、操作或生命周期改变时补充必要的逻辑测试。 |
| PluginKit API/ABI 或跨模块行为 | 此类代码改动推送前运行 `make ci`，已包含脚本测试、XCTest 和冻结客户端兼容检查。新引入的 API 登记到 `scripts/tests/test_plugin_minimum_host_compatibility.py`；使用已登记 API 须确保 `minHostVersion` 兼容，无需重复登记。 |
| 脚本、manifest 或 catalog | 独立逻辑运行相关脚本测试；包结构、schema、兼容性变化或新增公共 API 使用者运行 `make script-tests`。元数据或操作变化后运行 `python3 scripts/plugins/generate_website_plugin_data.py`。 |
| Panel drag routing or hit testing | Run the relevant model tests, then manually check the affected [panel interactions](docs/testing/panel-layout-editing.md). |
| Changelog 片段 | 提交或推送前运行 `make validate-changelog`。 |
| 仅文档 | 检查改动的链接、示例、格式与渲染效果，无需构建应用。 |

## 提交 Pull Request

使用 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md)，说明问题、最终行为、验证结果和相关限制，并关联 Issue。避免混入无关重构或格式化。贡献者应理解并验证全部提交内容，包括借助工具生成的代码。

**UI 改动必须提供前后截图。** 新增页面提供完成后的界面和入口说明。视觉改动展示浅色与深色外观；主题行为变化再补充一种代表性的自定义主题。拖拽、焦点、键盘导航等无法用静态图说明的行为，提供短录屏。保留足够的窗口上下文，并移除私人内容。

检查本次改动影响的交互、状态、翻译和窗口尺寸，不要求每个 PR 遍历全部场景。改变后台负载、采样频率、大量数据渲染，或声明性能提升时，提供可比较的前后观察；普通 UI 调整无需性能分析。详见[测量指南](docs/plugins/development-guidelines.md#performance-and-energy)。

请求 Review 前确认：

- [ ] 相关检查通过，PR 列出命令、结果及无法执行的检查。
- [ ] UI 改动附有截图或录屏，设计使用统一组件与主题。
- [ ] 用户可见变化已更新 README 或功能指南，并在 `changes/unreleased/` 添加英文片段。
- [ ] Manifest 元数据、API 兼容性、权限及操作策略与实现一致。
- [ ] 第三方来源与许可已记录，不含凭证、本地配置或无关生成物。

Changelog 片段使用 `release: app` 或 `release: plugin` 及支持的 `type`，每条不超过 220 个字符、两句话。涉及两个发布渠道时分别说明影响；纯文档改动无需发布片段。详见 [changelog 说明](changes/README.md)。

## 许可与发布

贡献须遵守 [LICENSE](LICENSE) 和 [LICENSING.md](LICENSING.md)。项目自有的应用、CLI、PluginKit、官方插件、工具及文档采用 **GPL-3.0-only**；仅提交你有权按相应条款提供的内容。第三方材料保留原许可与声明，在 [ThirdPartyNotices](Sources/Resources/ThirdPartyNotices/manifest.json) 中记录来源、固定版本、受影响产品、源码路径及许可文本。进入官方 catalog 的插件须采用兼容 GPLv3 的条款，除非许可政策另有明确例外。图标还须符合[素材目录规则](docs/icon-gallery.md)。

发布由维护者执行。功能 PR 不要提前递增插件版本、修改签名 catalog 或重新生成发布历史。发布相关工作请遵循[发布流程](docs/github-actions.md)、[插件 catalog](docs/plugins/plugin-catalog.md)和 [CLI 发布条件](docs/plugins/cli-release.md)。
