# StudyCore：独立摘录与笔记数据模块

本 Swift Package 按用户选定的 PDF 选区、摘录和笔记需求独立设计，不包含第三方应用代码或资源。依赖 Foundation，没有 PDF、OCR、界面或网络实现；这些功能由相邻 StudyApp 提供。

- `SourceSelection` 保存文档 ID、摘录全文和有序页面片段。每段包含从 0 开始的页索引、左上角原点的归一化矩形及 PDF 文字层/OCR 来源。`ocrOriginalText` 保存人工校正前原文，兼容缺少该字段的旧数据。
- `StudyExcerpt` 保存选区、笔记和时间，更新笔记保持来源不变。
- `ExcerptFileStore` 使用版本化 JSON 和原子替换，拒绝损坏数据、未知版本、重复 ID、来源变化和旧笔记覆盖。备份合并只接受最多 20 MB 的有效存档，来源冲突时整批拒绝。同一存储路径要求单一写入者。
- 模型构造与解码检查页序、非空文字、矩形范围、片段和时间顺序。跨页片段是独立设计，不证明其他应用支持同样能力。

备份包含摘录、OCR 原文和笔记，不包含 PDF。恢复后需重新导入同一 PDF 才能显示来源。导出的 JSON 为明文，由用户主动选择保存位置；应用侧设置本地文件保护和备份排除，多进程协调及真机保护效果未验证。

在 macOS/Swift 环境运行 `swift test`。`.github/workflows/studyreader-ios.yml` 会同时运行此包与 App 测试。提交 `3ab5d6228a3b4884e0578452cfcfbce50ac6426e` 的 Actions 运行 `41563242034` 中，10 项 StudyCore 测试通过；App 测试有失败，整体流程未通过。这不能作为新 IPA 交付证明。Windows 工作机没有 Swift/Xcode，实际运行记录以对应提交的 GitHub 日志为准。
