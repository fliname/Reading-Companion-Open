# macOS 0.55.6（Build 114）· 基于 0.55.4

本版修复两个电子书阅读遗留问题：

- EPUB / AZW3 / MOBI 图片缓存升级后自动重建，旧缓存不再继续保留失效的本地图片路径。
- 大图按当前阅读页正文高度缩放，避免图片在多栏分页时被挤出或截断。
- 页面偏下位置选中文字或点击已有划线时，操作浮窗固定锚定在选区下方。

同时保留 0.55.5 中基于 0.55.4 完成的 Obsidian 笔记属性与蓝色批注、全局方向键翻页、批量管理文件夹删除、已有划线修改和默认开启的 `ljg-read` 开关。

发布文件：

- `dist/Reading-Companion-Open-0.55.6-macOS-arm64.dmg`
- `dist/Reading-Companion-Open-0.55.6-macOS-Source.zip`
- SHA-256 见 `dist/SHA256SUMS-macOS-0.55.6.txt`。
