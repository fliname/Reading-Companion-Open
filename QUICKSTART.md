# Reading Companion Open 快速上手

## 使用前准备

- macOS 14 或更高版本，Apple Silicon Mac。
- 一份用户有权使用的 PDF。
- OpenAI、AIHUBMix、Anthropic、Google Gemini、DeepSeek 或 OpenRouter 的有效 API Key 与可用余额。
- 已安装的 Obsidian，以及一个已在 Obsidian 中打开过的 Vault。

## 初始化清单

1. 安装并打开 Reading Companion Open。
2. 按 `⌘,` 打开设置。
3. “AI”：已支持官方平台直接粘贴 Key；其他平台选“自定义 API”，粘贴连接信息或填写端点 → “验证并保存”。Azure、Responses、Anthropic 或无模型列表的接口展开“高级兼容”。
4. “Obsidian”：默认使用最近打开的 Vault 与 `Reading Companion` 目录；需要时可改选。
5. 导入 PDF → 等待全文提取/OCR 完成。
6. 打开“目录” → 自动识别 → 抽查标题、层级及页码跳转。
7. 复杂扫描目录会自动使用安装包内的增强识别；仍不准确时，用“手动添加”逐行粘贴并编辑。
8. 目录底部：“创建笔记本” → “添加目录到笔记” → “打开笔记本”。
9. 阅读时创建划线/批注或向 AI 提问；在相应列表中勾选内容并“加入笔记”。

## 无 API Key 时仍可使用

PDF 阅读、本地 OCR、PDF 自带目录、本地目录识别、书签、搜索、划线、批注和 Obsidian 原样写入不需要 API。AI 问答、章节概要、联网资源和 AI 整理需要 API，并由用户账户计费。

## 数据位置

- 项目缓存：`~/Library/Application Support/ReadingCompanionOpen`
- 公开版凭据：`~/Library/Application Support/Reading Companion Open`
- 笔记：用户选择的 Obsidian Vault

这些位置与原版 Reading Companion 分离。
