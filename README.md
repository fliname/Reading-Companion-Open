# Reading Companion Open

跨平台 PDF 深度阅读工具，面向理论书、学术著作和扫描书。支持本地 OCR、目录建立、划线批注、全文搜索、AI 伴读和 Obsidian 结构化笔记。

## 当前版本

| 平台 | 版本 | 系统 |
| --- | --- | --- |
| macOS | 0.43.12（Build 86） | macOS 14+，Apple Silicon |
| Windows | 0.43.23 | Windows 10/11，x64 |

安装包在 [Latest Release](https://github.com/fliname/Reading-Companion-Open/releases/latest) 下载。

## 主要功能

- **扫描 PDF 与文本 PDF**：文本页直接建立索引，扫描页在本机 OCR；两种 PDF 都会检测文件自带目录。
- **目录建立**：优先读取 PDF 自带目录；也可自动识别印刷目录、手动粘贴目录，并自动校准印刷页码与 PDF 实际跳转页。
- **划线与批注**：三色划线、批注、撤销/重做、列表搜索，并在 PDF 页面高亮定位。
- **隔页划线**：选完第一处后，macOS 按住 `⌘ Command`、Windows 按住 `Ctrl`，可在本页其他位置或其他页面继续选择；多处内容会合并为同一条划线。
- **全文搜索**：搜索结果直接定位并在页面高亮，可一键取消搜索。
- **AI 伴读**：围绕当前页、选中文本或全书索引提问，可生成章节概要和联网补充信息。
- **结构化笔记**：将目录、划线、批注和 AI 对话加入对应章节的 Obsidian 笔记。
- **阅读管理**：书架、缩略图、书签、旋转、缩放与阅读位置恢复。

## 手动目录格式

推荐每行一个条目，同时保留标题与书中印刷页码：

```text
前言 ........ i
第一部分 物的世界 ........ 1
 第一章 非物 ........ 9
  第一节 信息与秩序 ........ 15
```

- 行首每增加一个空格，表示下一级目录。
- 页码可以放在标题前或标题后；支持阿拉伯数字、罗马数字、点线、空格或斜杠分隔。
- 也可粘贴标题列和独立页码列，但“一行一条”最稳定。
- 条目中的页码是书本印刷页码；应用会依据正文标题、PDF 页标签和目录位置校准实际 PDF 跳转页。保存前请抽查首条、正文第一章和末条。

## 安装

简要步骤见 [INSTALL.md](INSTALL.md)。

## 源码

- `macOS/`：Swift、SwiftUI、PDFKit、Vision。
- `Windows/`：Electron、PDF.js、Tesseract.js。

macOS：

```bash
cd macOS
swift test
./scripts/build-app.sh
```

Windows（建议在 Windows x64 环境构建）：

```powershell
cd Windows
corepack enable
pnpm install --frozen-lockfile
pnpm test
pnpm run dist:win
```

## 说明

- AI 功能需要用户自行配置受支持服务商的 API Key；PDF 阅读、OCR、目录、搜索和划线不依赖 AI。
- 社区安装包使用临时签名，未进行 Apple 公证或 Windows 商业代码签名。
- 项目采用 [MIT License](LICENSE)。
