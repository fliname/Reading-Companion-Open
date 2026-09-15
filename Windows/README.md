# Reading Companion Open for Windows

当前版本：0.44.3。此版本以 Windows 0.44.1 为基线同步 macOS Open 的阅读功能。Windows 版仅提供公开版，不包含 Claude 网页端或任何第三方网页自动化代码；用户自行配置 API Key。

Reading Companion Open 是面向 Windows 10/11 x64 的 PDF / EPUB / AZW3 / MOBI 伴读工具，集成流式电子书排版、本地 OCR、目录识别、三色划线与批注、AI 问答、人物索引、书架和 Obsidian Markdown 笔记。

## 第一次使用

1. 运行 `Reading-Companion-Open-0.44.3-Windows-x64-Setup.exe`；若使用 Portable 包，则解压完整 ZIP 后运行 `Reading Companion Open.exe`。
2. 安装并启动 [Obsidian](https://obsidian.md/download)，创建或打开一个 Vault。Reading Companion 会优先使用 Obsidian 已注册且最近打开的 Vault；也可在“设置 > Obsidian”中选择另一个已注册 Vault。
3. 在设置中输入 API Key。官方服务可只填 Key；独立中转站同时填写 Base URL，或粘贴 `newapi_channel_conn` JSON。连接成功后，在 AI 伴读栏选择当前 Key 实际可用的模型。
4. 导入 PDF、EPUB、AZW3 或 MOBI，并选择“非虚构类”或“虚构类”。等待本地提取、解码/OCR、排版与索引完成。
5. 先核对目录，再依次点击“创建笔记本”“添加目录”“打开笔记本”。

## 主要功能

- EPUB 3 `nav`、EPUB 2 `NCX` 与内嵌封面；EPUB/AZW3/MOBI 使用白底流式正文，字号和栏宽变化后实时重排，支持单页/双页、动态页码、滚轮翻页和源文件指纹缓存。
- 无 DRM 的 MOBI/KF8/AZW3 由安装包内 libmobi 0.12 `mobitool.exe` 在本机以独立进程转换，不上传书籍；带 DRM 文件不支持。
- 首次加入和升级后的旧书必须选择书籍类型。非虚构类保留阅读深度、快捷问题和章节结构概要；快捷问题区的 `ljg-read` 开关默认开启，关闭后使用基础原文问答，并按书保存选择。虚构类不加载学术框架、不追加碰撞问题，默认 120–300 个汉字，并保留“联系全书”。
- 虚构类“概要”按当前阅读器实际页码提取起止页文字，每次结果独立保存；“人物”支持批量/单个添加、修改、删除、别名、独立颜色、全文高亮、首次强调、最多 11 次邻近出现和上/下一次精确跳转。PDF 与流式电子书均可使用。
- 书架固定提供全部、非虚构、虚构和自建文件夹；同一本书可属于多个文件夹。文件夹删除键只在批量管理中显示，确认后只删除文件夹及成员关系，书籍继续保留。

- 单页连续阅读、适宽/适页/缩放/旋转、纵向锁定、触控屏双指缩放、底栏翻页、书签与全文搜索；可把 PDF 直接拖入窗口打开，搜索命中同时在结果列表和 PDF 原文中以黄色标出。
- PDF 自带目录优先；无目录时由轻量 JavaScript 引擎复用现有文本层并按需调用内置 OCR，最多扫描前部 48 页，不包含 EnhancedTOC、Python、Torch 或联网模型；支持双栏、窄栏、竖排页眉、无页码篇章标题及手动解析和批量编辑。
- 目录建立工具默认折叠，点击“目录”后显示“自动识别、手动添加、恢复自带目录”；打开 PDF 时先读取原生目录，缺失时明确显示“PDF 无自带目录”。
- 手动添加目录会原位替换右侧 AI 面板；每行输入一条“标题 + 页码”，条目始终显示用户粘贴的印刷页码，旁边的“PDF”栏显示并允许修正实际跳转页。软件自动锁定真实目录物理页，再以正文标题、分页分段、多条目插值和 PDF 页标签校准跳转页；强制 OCR 不会再覆盖复杂底图章页中仍可用于定位的 PDF 文本层。
- 文本型 PDF 直接提取；扫描件使用内置 Tesseract 简体中文/英文 OCR，并在页面上生成可选择的透明文字层；即使 OCR 引擎未返回标准文本块，也会从逐词坐标重建行并启用拖拽划线、批注、复制和提问，不要求另行下载识别软件。
- 选区浮窗支持黄/红/蓝划线、绿色批注、复制和提问；Ctrl 可连续跨页选择并合并。扫描页使用纵向优先锁行和逐词坐标收口，不会跨行回跳或涂到行末空白。
- “划线与批注”栏可同时搜索划线原文和批注文字，并在匹配条目中标出关键词；颜色与批注筛选可和搜索组合使用。
- PDF 在本机整理为章节化 Markdown 并建立持久化索引。AI 默认只发送相关章节片段；开启“联系全书”才跨章检索。
- 节省、均衡、深读三级范围；深读增加输出预算，服务端单次触顶时自动续写并以短结论强制收束，不再弹出输出上限错误或丢弃已生成答案；新原文自动关闭旧上下文，同一原文追问才保留历史；显示上轮 Token、缓存和范围。
- 启动后自动检查 GitHub Release；发现对应 Windows 新安装包时可选择立即下载并启动升级、稍后提醒或忽略该版本，也可在“帮助 > 检查更新”手动检查。
- 支持 OpenAI、Anthropic API、Google Gemini、DeepSeek、OpenRouter、AIHubMix，以及实现兼容接口的独立中转站。
- 划线、批注、AI 问答按章节写入 Obsidian；工具栏与笔记中心均可进入笔记操作，AI 笔记为紫色，支持原文或约 30% 浓缩，默认展开。
- 搜索提交时保持当前阅读页；只有点击某条结果才精确跳到该次文字命中，同页重复词也分别定位。
- 书架默认在当前空窗口打开第一本书；需要并行阅读第二本时才新建窗口。删除缓存可彻底重置该书，但不会删除源文件或 Obsidian 笔记。

## 隐私与成本

OCR、电子书解码/排版、文档转 Markdown、索引、检索、书签、人物和笔记整理均在本机完成。只有发送 AI 问题、AI 目录识别或生成概要等明确调用模型的操作会访问用户配置的服务。API Key 在 Windows 上使用 Electron `safeStorage`（Windows DPAPI）加密保存。

缓存位于 `%APPDATA%\\reading-companion-windows\\ReadingCompanion\\Documents`。在应用书架中选择“删除缓存”是推荐的单书重置方式。

Obsidian 笔记使用 `vault + 相对文件路径` 打开，不再把 Windows 绝对路径作为 `path` 参数传入。若提示未找到 Vault，请先在 Obsidian 中选择“打开文件夹作为仓库”，再回到 Reading Companion 的 Obsidian 设置中选择该仓库根目录。

## 开发

需要 Node.js 22+ 与 pnpm：

```powershell
pnpm install
pnpm test
./scripts/build-libmobi-windows.sh # 在 GitHub Actions 的 MSYS2/MinGW 环境执行
pnpm start
pnpm run dist:win
pnpm run dist:zip # 无需 NSIS，可生成可直接解压运行的 Portable 包
```

构建产物位于 `dist`。详见 [0.44.0 发布说明](RELEASE_NOTES_0.44.0.md)、[快速上手](QUICKSTART.md)、[故障排查](TROUBLESHOOTING.md)、[功能迁移清单](FUNCTION_PARITY.md) 与 [Windows 验证说明](WINDOWS_TESTING.md)。

## 许可

应用代码采用 MIT License；随包 libmobi 0.12 与 `mobitool` 采用 LGPL-3.0-or-later，并作为独立进程调用。参见 [隐私说明](PRIVACY.md) 和 [第三方声明](THIRD_PARTY_NOTICES.md)。
