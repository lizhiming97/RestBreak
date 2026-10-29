# 截图标注（第二期）Implementation Plan

> **状态：已完成（v0.4.0，2026-10-22）。** 下面的勾选框没有逐条打勾，以本行为准；实际实现以代码和 docs/项目细节.md 为准。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 在框选界面直接标注（8 个工具、可选中移动删除改样式、撤销重做），导出合成图；工具栏换成浅色统一图标。

**Architecture:** 纯逻辑 `Engine/Annotation.swift`（模型 + 命中 + 撤销栈）；唯一绘制代码 `UI/AnnotationRenderer.swift`（屏上图层和导出共用）；SwiftUI 工具栏 `UI/AnnotationToolbar.swift`；`CaptureView` 负责把鼠标键盘转成标注操作。

**设计文档:** `docs/superpowers/specs/2026-10-22-annotation-design.md`

测试命令 `$TEST`：`cd RestBreak && xcodebuild test -scheme RestBreak -destination 'platform=macOS' 2>&1 | grep -E "error:|✘|Test run with"`

---

### Task 1: 标注模型（Engine，TDD）
**Files:** Create `RestBreak/Engine/Annotation.swift`，Test `RestBreakTests/AnnotationTests.swift`；Modify `Engine/AppSettings.swift`（`annotationStyles`）
- [ ] 写测试：⇧ 约束（矩形→正方形、箭头→45°、荧光笔直线）；包围框；命中（矩形边上命中/内部不命中、马赛克内部命中、箭头线段附近命中、取最上面的）；移动；`nextNumber`（空=1、[1,3]→4）；各档线宽；`AnnotationDocument` 增删改、撤销/重做、拖动移动只记一次、重做在新操作后清空；`annotationStyles` 默认值与旧设置兼容。
- [ ] 运行确认失败 → 实现 → `$TEST` 通过 → 提交「标注：模型、命中、撤销重做」

### Task 2: 绘制（AnnotationRenderer，TDD）
**Files:** Create `RestBreak/UI/AnnotationRenderer.swift`，Test `RestBreakTests/AnnotationRendererTests.swift`
- [ ] 写测试（用纯色底图）：无标注导出 = 裁剪原图尺寸和颜色；红色矩形边上像素红、内部为底色；马赛克（用四色图）区域像素变化；文字区域出现非底色像素；箭头终点附近为箭头颜色；Retina（scale 2）导出尺寸翻倍。
- [ ] 实现 `drawComposite`、`export`、`textSize`、`MosaicCache` → `$TEST` 通过 → 提交「标注：绘制与导出」

### Task 3: 浅色工具栏
**Files:** Create `RestBreak/UI/AnnotationToolbar.swift`；Modify `UI/CaptureOverlay.swift`（删除旧 `CaptureToolbar`）
- [ ] `AnnotationToolbarModel`（tool、styles、selectedStyle、canUndo/canRedo、回调）、主工具栏、属性条、悬停/选中/禁用状态、Liquid Glass 与旧系统外观 → 编译通过 → 提交

### Task 4: 框选界面接入标注
**Files:** Modify `UI/CaptureOverlay.swift`、`App/ScreenshotController.swift`、`App/BreakCoordinator.swift`
- [ ] 标注图层（选区大小）、虚线框图层、绘制草稿、选中/移动/删除、文字编辑（NSTextField）、序号、数字键、⌘Z/⌘⇧Z、Esc 顺序与两次确认、`selectedImage()` 导出合成图、样式回写设置 → 编译 + `$TEST` 通过 → 提交

### Task 5: 验证与收尾
- [ ] 渲染图人工检查（工具栏外观除外）；全部测试；更新 CLAUDE.md；提交。
