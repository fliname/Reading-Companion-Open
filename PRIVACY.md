# 隐私说明

Reading Companion Open 没有自有服务器、广告或分析 SDK。

## 本地处理与保存

- PDF 阅读、系统 OCR、目录识别、检索索引、书签、划线和批注主要在本机处理。
- 阅读状态与对话缓存在 `~/Library/Application Support/ReadingCompanionOpen`，密钥保存在 `~/Library/Application Support/Reading Companion Open`；两者均与原版 Reading Companion 隔离。Obsidian 内容只写入用户主动选择的 Vault。
- API Key 不进入源码、日志或 UserDefaults。当前本地分发版将长期密钥保存在仅当前用户可读的私有凭据文件中；不勾选“记住”时只保存在本次运行内存中。

## 何时发送网络请求

- 用户粘贴 Key 后，应用调用候选平台的模型列表/密钥状态接口完成自动识别，不发送 PDF、目录或问题内容。AIHUBMix 因模型目录可公开返回，会额外收到一次只有 1 个输入字符、最多 1 个输出 token 的最小认证请求。
- 用户主动发送 AI 问题、生成章节概要或整理对话时，应用才会把问题及检索出的相关原文片段发送给已识别的 AI 服务商。
- 开启“联系全书”时，会额外发送目录与跨章节检索片段，但不会上传整份 PDF。
- “链接资源”会请求所选服务商使用联网搜索能力，费用和数据处理受该服务商条款约束。
- 语音输入优先使用 macOS Speech；是否由 Apple 在线处理取决于设备、语言和系统能力。
- 可选的增强目录识别会下载开源 OCR/文档解析组件并在本机运行，不上传 PDF。

## 删除数据

删除 `~/Library/Application Support/ReadingCompanionOpen` 与 `~/Library/Application Support/Reading Companion Open` 可清除公开版项目缓存和已保存凭据；这不会删除原 PDF、原版 Reading Companion 数据或 Obsidian Vault。已写入 Vault 的内容应由用户在 Obsidian 中删除。

用户应确保对打开的 PDF 及发送给第三方服务商的内容具有合法使用权。
