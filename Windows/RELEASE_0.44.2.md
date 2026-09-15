# Windows 0.44.2 · 基于 0.44.1

## 本次修改

- EPUB / AZW3 / MOBI 正文图片支持父目录引用、URL 编码、大小写不一致及 SVG `href` / `xlink:href`。
- Obsidian 新笔记以 YAML 属性开头；批注文字显示为蓝色，与原文分开。
- 阅读窗口中的普通控件获得焦点后，四个方向键仍可翻页。
- 书架文件夹删除键只在“批量管理”中出现。确认后只删除文件夹及成员关系，书籍、源文件和阅读记录继续保留。
- 电子书已有划线可再次点击，重新打开划线浮窗并修改颜色或批注。
- 页面下方拖选时，划线浮窗贴近选区向上展开并保持在可见窗口内。
- 快捷问题区新增 `ljg-read` 开关，默认开启；关闭后下一轮 AI 对话使用基础原文问答。选择按书保存，回答缓存按开关状态隔离。

## 验证

- 58 项 Node 测试全部通过。
- Chromium 真实交互验证通过：Skill 开关、普通按钮焦点下方向键翻页、页面下方浮窗、已有划线点击改色、文件夹删除键显示条件、确认框和书籍保留。
- Windows 源码和运行资源从已校验的 0.44.1 Portable 包恢复后修改。未在 Windows 10/11 真机执行安装、卸载、DPAPI、系统语音和实际 MOBI 转换验收。

## 发布文件

- `dist/Reading-Companion-Open-0.44.2-Windows-x64-Setup.exe`
- `dist/Reading-Companion-Open-0.44.2-Windows-x64-Portable.zip`
- SHA-256 见 `dist/SHA256SUMS-0.44.2.txt`。
