# 长截图实施计划

状态：完成，随 0.7.7 发布（2026-11-09）。设计：`docs/superpowers/specs/2026-11-09-scrolling-screenshot-design.md`。

- [x] 1. `Engine/ScrollStitcher.swift`：行签名、位移匹配（固定区/往回/无重叠/无变化）、拼接计划、长图合成；单测 `ScrollStitcherTests`（合成数据）。
- [x] 2. 标注宿主改为 `annotationSource (image, scale)`，让长图窗口能复用 `AnnotationEditor`；现有截图行为不变（全部测试通过）。
- [x] 3. `App/ScrollingCaptureSession.swift` + `UI/ScrollingCapturePanel.swift`：选区截屏（排除自身）、滚轮监听 + 0.25 秒兜底、缩略图、完成/取消、高度上限。
- [x] 4. `UI/LongImageWindow.swift`：可滚动长图 + 标注（选区 = 可见区域）、复制/保存/贴图/提取文字/翻译、完成提示。
- [x] 5. 接入：工具栏「长截图」按钮、`CaptureAction.scroll`、快捷键 `ShortcutAction.scrollingCapture`（框选松手直接开始）、设置「截图」页。
- [x] 6. 全部测试、构建、文档（项目细节、CLAUDE.md），本地测试包交用户真机试。
