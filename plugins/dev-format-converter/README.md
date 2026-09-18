# dev.format-converter

本地格式转换插件，把聊天归档转换为 Markdown，并提供可复用服务 `document.convert@1.0.0` 供其他插件与 Agent 调用。

## 当前状态

已从未发布的原型迁移到 manifest 1.2，并可作为真实服务被调用：

| 文件 | 说明 |
|---|---|
| `manifest.json` | manifest 1.2；权限逐项声明；声明 `document.convert`，`agentCallable: true`、`requiresUI: false` |
| `schemas/*.json` | 服务参数与结果 schema，加载器校验其存在且不出包 |
| `service/index.js` | 服务实现；演示阶段由宿主的子进程运行时承载 |
| `ui/index.html`、`ui/assets/*` | 页面逻辑；内联脚本已外置以符合自带 CSP |

验证方式见[开发环境与运行说明](../../docs/开发环境与运行说明.md)：演示器会通过 `host.service.call` 调用本插件，并由 Agent 会话调用同一实现。

## 迁移完成情况

原型的下列问题已处理：

- `records` / `author` 改为标准归档的 `messages` / `authorId`，并在转换前校验归档结构。
- manifest 的 `storage.plugin.read/write` 缩写已拆为两个独立权限。
- 通配 `postMessage` 改为宿主注入的受信通道；页面不再向任意窗口广播。
- 内联脚本与样式已移到 `ui/assets/`，`script-src 'self'` 不再冲突；`host.file.save` 改为提交结果句柄。
- 转换逻辑独立成服务，按钮与 Agent 调用同一份实现。

## 尚未处理

- 正在运行的是子进程替身运行时，**不是** WebView 沙箱；CSP 实际拦截与导航阻断未验证。
- 只实现 Markdown 目标格式；原型的 CSV / HTML 输出未迁移。
- 输出转义只覆盖 Markdown 结构字符，CSV 公式注入等场景随对应格式迁移时单独处理。
- 未做包快照与数据迁移，升级回滚能力尚未实现。
