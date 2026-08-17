# Reading Companion Open

当前版本：0.42.16（Build 76）。这是可与原版 Reading Companion 并存的公开版，使用独立的应用名称、Bundle ID、设置、缓存和密钥目录。

一个原生 macOS PDF 伴读应用：本地 OCR、带页码 AI 问答、三色划线与 Obsidian 结构化笔记。

## 第一次使用：从安装到生成笔记

### 1. 安装公开版

1. 打开 `Reading-Companion-Open-0.42.16-macOS-arm64.dmg`。
2. 把 **Reading Companion Open** 拖入 **Applications**。它与原版 Reading Companion 使用不同名称、Bundle ID 和数据目录，可以同时安装。
3. 首次启动若被 macOS 拦截，请在 Finder 中右键应用，选择“打开”。当前社区安装包使用临时签名，尚未经过 Apple 公证。

### 2. 自行购买 API 并输入密钥

应用不附赠 API 额度，也不会代用户购买。支持以下服务商：

- **OpenAI 官方**：在 [API Keys](https://platform.openai.com/api-keys) 创建密钥，并在 [Billing](https://platform.openai.com/settings/organization/billing/overview) 单独充值。ChatGPT Plus/Pro 订阅不等于 API 额度。
- **AIHUBMix**：在 [AIHUBMix Token](https://aihubmix.com/token) 创建 Key，并在平台账户中充值、开放所需模型权限。第三方平台的价格、可用地区和数据政策由该平台决定。
- **Anthropic 官方**：使用 Claude Console 创建的 API Key，通过原生 Messages API 调用。
- **Google Gemini**：使用 Google AI Studio 创建的 Gemini API Key。
- **DeepSeek 官方**：使用 DeepSeek 开放平台创建的 API Key。
- **OpenRouter**：一个 Key 可调用多家服务商模型，费用和数据路由由 OpenRouter 账户设置决定。
- **自定义 API**：可粘贴平台提供的 `newapi_channel_conn`，或输入 Base URL/完整端点。支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Azure `api-key` 认证，以及本机 Ollama/vLLM；无 `/models` 时可填写模型 ID 或 Azure Deployment。

然后在应用中：

1. 点击 AI 伴读栏右上角的齿轮，或按 `⌘,`。
2. 在“AI”页直接粘贴 API Key。界面只显示正在验证、连接成功或未连接；兼容探测在后台完成，不上传 PDF 或问题内容。
3. 需要长期使用时勾选“记住 API Key”，点击“验证并保存”。验证成功后窗口会自动关闭。
4. 回到 AI 伴读栏选择已获授权的模型与阅读深度。

连接信息示例：`{"_type":"newapi_channel_conn","key":"sk-…","url":"https://relay.example.com"}`。粘贴后原始字符串会立即清除，Key 以密码形式显示；请再点击“验证并保存”。普通中转站只需提供 Key 与 Base URL。Azure 或特殊平台可粘贴带查询参数的完整端点，在“高级兼容”中选择协议与认证；没有模型列表时填写模型/Deployment ID。本机服务允许 `http://localhost`/`127.0.0.1`，其他远程地址必须使用 HTTPS。

### API 兼容范围

直接识别：OpenAI、Anthropic、Google Gemini、DeepSeek、AIHUBMix、OpenRouter。

通过“自定义 API”兼容：Azure OpenAI/Foundry（API Key）、xAI、Mistral、Moonshot/Kimi、阿里云百炼/通义千问、火山方舟/豆包、腾讯混元与 LKEAP、智谱 GLM、MiniMax、硅基流动，以及采用 NewAPI、OneAPI、LiteLLM、Ollama、vLLM 等 OpenAI/Anthropic 兼容协议的平台。平台仍须允许当前 Key 使用所选模型，并返回标准文本响应。

不能保证：AWS Bedrock IAM/SigV4、Google Vertex AI ADC/OAuth 自动刷新、Azure Entra ID、需要临时令牌/客户端证书/自定义签名的平台，以及仅提供厂商原生非兼容协议的接口。它们需要相应云账户的凭据代理或官方 SDK，不能安全地由一个“API Key”输入框通用处理。

### 3. 安装 Obsidian 并设置笔记路径

1. 从 [Obsidian 官网](https://obsidian.md/download) 安装并启动 Obsidian。
2. 在 Obsidian 中创建 Vault，或使用“打开文件夹作为仓库”打开已有 Vault。必须先让 Obsidian 注册这个 Vault。
3. Reading Companion Open 会优先连接 Obsidian 最近打开的 Vault，并在其中使用默认目录 `Reading Companion`；也可在“设置 > Obsidian”中改选 Vault 根目录。
4. 应用会在默认目录中为每本书建立简洁的 Markdown 笔记。

### 4. 导入 PDF 并识别目录

1. 点击“打开 PDF”或把 PDF 拖入应用。
2. 等待底部/右侧状态显示全文提取或 OCR 完成。文本型 PDF 会直接提取，扫描件会调用 macOS Vision 在本机 OCR。
3. 打开左侧“目录”。应用先检查 PDF 自带目录；没有可信目录时再定位印刷目录页并识别。
4. 核对每条标题、层级和跳转页码。增强目录识别已包含在安装包中，会自动处理复杂双栏、竖排或低质量扫描件；仍不准确时使用“手动添加”，保证粘贴文本每行一条目录，再修改标题、页码、层级和顺序。
5. 在写入笔记前至少抽查第一条、正文第一章和最后一条能否跳到正确页面。目录写入后仍可更新，但先校对能避免错误骨架进入笔记。

### 5. 把目录导入 Obsidian 笔记

1. 在目录栏底部点击“创建笔记本”，先建立本书的 Markdown 文件。
2. 点击“添加目录到笔记”，把当前已经校对的目录作为章节骨架写入该笔记。
3. 点击“打开笔记本”在 Obsidian 中检查结果。
4. 此后，划线、批注和 AI 对话可从各自列表选择“加入笔记”，应用会依据提问或原文所在页，写到对应章节下方。

更精简的操作清单见 [快速上手](QUICKSTART.md)，常见错误见 [故障排查](TROUBLESHOOTING.md)。

## 当前可用

- 原生三栏 PDF 阅读界面，支持打开和拖放 PDF。
- 单页连续阅读、整页/适宽/自定义缩放；页面锁定后直接接管滚轮，只改变纵向坐标，彻底消除横向位移和回弹抖动。页码和翻页控制统一位于底栏。
- 页面缩略图导航、可命名书签和页面旋转；工具栏书签在当前页添加后显示为红色，并自动打开书签导航。
- 严格目录页识别：优先采用 PDF 自带目录；否则定位连续印刷目录页。结构解析前先统一 Unicode 兼容字、竖排“目/录”页眉残片、中文逐字空格、空格分隔页码（如 `1 9 -> 19`）、斜杠、点线与单点页码；自动识别和手动粘贴共用同一规范化入口，再同时运行逐行与灵活版面两套候选解析，以完整条目、页码覆盖率和页码单调性选择结果。视觉 OCR 会比较横排、双栏与竖排候选顺序；映射时优先采用 PDF 声明的页标签，再用多个章首标题的一致偏移校准物理页，避免正文重复标题带偏全书页码。
- 目录缓存按解析算法版本迁移：新版首次打开项目会清除旧算法生成的自动目录，但保留 PDF、阅读位置、书签、划线、批注、对话、概要和用户手动编辑的目录；本地识别与 AI 精修结果都写入版本，点击重新识别时不再沿用失败前的旧自动结果。
- 目录识别明确分成两条入口：“自动定位并识别”会搜索全书选择目录页；“指定目录页”跳过定位，只读取当前页起的精确范围。两者共用同一套可靠抄录器：本地逐行防漏结果与 AI 结构化结果合并，保护第一条、序/前言/引言、跨页条目，并分别校准罗马前置页码与正文阿拉伯页码。
- “粘贴或手动编辑”使用明确的逐行格式：每行一个条目，序号可省略且可放在标题前后，行首空格数直接决定层级；双栏复制导致的交错顺序会按序号恢复。印刷页码再通过正文标题锚点换算为 PDF 物理页，未匹配条目不会消失，识别后仍可修改标题、页码、层级和顺序。手动结果随文档保存。
- 页码跳转、方向键翻页、工具栏与书签侧栏的明确入口（⌘D 添加当前页）、全文搜索。
- 选区浮窗把“划线”“批注”“复制”“提问”分开：三色色块直接完成划线；绿色下划线在原文下方打开无边框两行批注框，回车发送、Shift+回车换行、点击框外取消；提问恢复系统气泡图标。工具栏划线图标可切换持续划线模式。
- Apple Vision 本地 OCR 与带章节/页码的全文分块索引。首次处理完成后，页级 OCR/Markdown 和绑定当前目录结构的全文索引会持久化保存；再次打开同一 PDF 可直接复用。目录变化时只重建索引，PDF 被替换或修改时自动废弃旧缓存。
- AI 问答不会上传整本 PDF：先在本机以章节结构化 Markdown 建索引，再用相关性检索选出证据；发送前去除重叠片段并执行阅读深度对应的 Token 上限。新选段自动关闭旧对话上下文，明确追问才继承；同一问题可命中本地回答缓存。回答下方会显示输入、输出及服务商返回的缓存命中量，便于核对实际消耗。
- 回答在生成前按阅读深度规划：节省为 1,500 Token 安全上限、约 700–1,000 个汉字；均衡为 3,000 Token、约 1,200–1,800 个汉字；深读为 5,000 Token、约 2,000–3,000 个汉字。应用不会在生成后截断答案，而会要求模型在上限前完整收束。
- Token 用量优先读取服务商返回的标准或常见中转格式；若服务商省略 usage 或只返回合计，应用会显示带“约”的本机估算值，不再把缺失数据误显示为 0。
- 模型和阅读深度右侧的“上轮用量”可查看上一轮的模型、范围、证据片段数、输入/输出/推理 Token、缓存写入与缓存命中率；若命中本地回答缓存，会明确显示本轮没有调用 API。
- macOS Speech 连续语音输入；停顿会确认当前片段并自动继续听写，已识别内容持续累积，主动结束后也完整保留。权限、实时音频和识别结果三类系统回调均通过非隔离桥接后再更新界面，避免 Swift 6 执行器检查导致闪退。
- OpenAI-compatible AI 问答内嵌 `ljg-read 1.2` 阅读协议：优先校正可靠的 OCR 错字，拆开相连问题，区分理论来源/研究对象/分析层级/操作方法/证据/结论，重建前后文论证位置；读者回应后提炼其判断标准并重新检验原文。检索会同时带入焦点段、前后页和语义邻块，伴读请求使用中等推理强度。引用缩写为 `P页码`；“链接资源”精选五条以内并显示为卡片。
- AI 设置只要求输入 Key 并显示连接结果；后台兼容 OpenAI、AIHUBMix、Anthropic、Google Gemini、DeepSeek 与 OpenRouter，并只加载当前 Key 实际获准调用的文本模型。
- API Key 可按服务商长期保存在仅当前 Mac 用户可读的本机应用数据中（目录权限 `700`、二进制凭据文件权限 `600`），并在应用重启后自动恢复；也可选择仅用于本次运行或清除。临时签名版本不再访问 Keychain，彻底避免换版后反复弹出登录密码窗口；正式 Developer ID 签名后迁回 Keychain。
- 工具栏“笔记”保留 Vault、目录、划线/批注和 AI 对话操作；Obsidian 使用内置 warning/danger/info/success/question 色块，无需启用 CSS 即可区分三色划线、绿色批注和 AI。旧笔记会在下次写入时迁移颜色并移除 Reading Companion HTML 注释。
- 目录右侧“概要”切换每个条目的展开键；展开后按“问题—论证—结论—承上/启下”分行显示为四色结构卡，关键概念或判断会同时加粗并划线。概要只在应用内缓存。
- AI 对话支持勾选后加入笔记或删除；侧边“问题速览”从所选原文提取核心短句并标注提问意图，不再重复“解释一下/联系上下文”模板，点击即可跳到对应对话。
- AI 请求等待期间，“发送”会变成红色“取消”；点击后立即中止网络任务、恢复原问题与本次阅读范围，并移除尚未回答的临时提问。服务商已经接收或处理的部分仍可能按其规则计费。
- PDF 检索保存完整目录层级，并按正文中标题的实际位置切分同页内容；默认范围采用“当前小节的最近逻辑父级”，可在不增加片段上限的前提下同时检索兄弟小节。直接输入的问题锚定当前页，明确追问沿用最近选段页码；语义命中片段优先于单纯邻近页面。
- 公开版只保留用户自行配置密钥的 API 伴读，不嵌入或自动操作第三方聊天网页。模型与阅读深度在伴读栏顶部切换，全文提取/OCR 进度始终可见。
- PDF 中拖选文字会弹出横向划线、绿色批注和“AI 提问”；点击已有划线会选中整条，选择批注并发送后会把原划线转换为批注，避免重复记录。左侧支持单独筛选批注。
- 划线、批注和 AI 对话会按“章节标题 + 页码”定位到 Obsidian 的对应目录下；AI 对话使用提问发生页作为固定章节锚点，不会被回答引用的其他证据页带到前一章，多章选择会分章写入。已有笔记缺少新识别的章节标题时会补齐标题且保留手写内容，底栏显示写入成功反馈。
- AI 对话以完整问答单元加入笔记：即使问题或回答曾被旧版本标记为已写入，选择其另一半时仍会补齐配对内容。“保留原文”不截断正文；“整理浓缩”目标约为原对话的 30%，并保留每组问答的直接答案、关键区分、主要论证和结论。
- 没有 API Key 时，PDF 阅读、OCR、可信原生目录、缩略图、书签、搜索、划线批注、导出和 Obsidian 本地笔记仍可独立使用。
- 应用拥有区块与手写笔记分离；核心合并逻辑已有测试。

## 尚待增强

- 复杂扫描书若把目录排成图片或多栏，目录页 OCR 质量仍会影响结果；界面会明确显示定位到的 PDF 目录页范围，便于核对。
- AI 当前为完成后显示，尚未实现流式增量输出和取消请求。
- 高亮跨页分组和将视觉 OCR 文本层真正写回 PDF 尚未完成。
- Obsidian 目前通过原子写入保护内容，后续还需文件协调器与冲突合并 UI。
- 正式分发需要完整 Xcode、Developer ID 签名和 Apple 公证。

完整范围见 [PRODUCT_SPEC.md](PRODUCT_SPEC.md)，实施约束见 [BUILD_PROMPT.md](BUILD_PROMPT.md)。

## 构建与运行

直接构建和测试：

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/reading-companion-clang-cache \
  swift test --disable-sandbox \
  --scratch-path .build \
  --cache-path /private/tmp/reading-companion-swiftpm-cache \
  --config-path /private/tmp/reading-companion-swiftpm-config \
  --security-path /private/tmp/reading-companion-swiftpm-security
```

生成可双击的本地 `.app`：

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
```

产物位于 `dist/Reading Companion Open.app`。当前使用临时本地签名，适合本机开发验证，不适合直接分发。

生成 GitHub 源码发布包：

```sh
chmod +x scripts/package-github-source.sh
scripts/package-github-source.sh
```

首次使用 AI 时，在设置中输入真实 API Key，然后点击“验证并保存”；连接成功后设置窗口自动关闭。首次写入笔记时，应用会优先使用 Obsidian 最近打开的 Vault，也可从工具栏“笔记”改选。

## 开源、隐私与商标

本仓库采用 MIT License。应用不附带 API Key、PDF 样本或第三方聊天网页自动化代码；图标中的紫色便笺是通用原创图形，不包含 Obsidian 标志。Obsidian、OpenAI、AIHUBMix 等名称仅用于说明兼容性，本项目不受这些服务商背书。使用前请阅读 [隐私说明](PRIVACY.md)、[第三方声明](THIRD_PARTY_NOTICES.md) 和 [贡献指南](CONTRIBUTING.md)。

首次点击麦克风时，macOS 会询问语音识别与麦克风权限。若曾拒绝，请前往“系统设置 > 隐私与安全性 > 语音识别”和“麦克风”重新开启。

打开设置的方法：点击 AI 伴读栏右上角的滑杆按钮，或选择菜单栏“Reading Companion Open > 设置…”，也可以按 `⌘,`。在“Obsidian”标签中点击“选择 Obsidian Vault…”。
