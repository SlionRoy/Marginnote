# StudyReader：iPhone / iPad 工程草案

这是独立实现的移动端入口，不使用原 IPA 的代码或资源。使用系统 PDFKit 处理已有文字层的 PDF，并把摘录、笔记交给相邻的 `StudyCore` Swift Package 保存。

在 macOS 上用 Xcode 16 或更新版本打开 `StudyReader.xcodeproj`，选择 iPhone 或 iPad 模拟器，运行共享的 `StudyReader` scheme。真机安装需将示例 Bundle Identifier 改为自己的值，并配置开发团队。工程目标最低 iOS 18。当前 Windows 工作机没有 Xcode/Swift，因此这些步骤尚未执行，工程是否能构建还需以 Xcode 结果为准。

当前源码预期交互：导入 PDF → 选中文字 → 点“摘录选区” → 写笔记 → 在摘录列表打开并跳至来源区域。扫描页可点“识别本页”，使用系统 Vision 在设备上识别，在扫描页预览点选识别区域或从列表勾选同页的一行或多行候选文字、统一校正，再建立标记为 OCR 来源的摘录和笔记。“文件”菜单提供用户主动导出明文 JSON 备份、从所选 JSON 合并恢复。iPhone 使用单栏阅读和单独的摘录列表；iPad 横向空间使用并列列表。文档副本和 `excerpts.json` 存于应用的 Application Support。导入先复制到临时文件并核对 SHA-256，再移入文档目录；重用和重开已有文件时也核对摘要；上次 PDF 副本缺失或无法解析时给出错误提示。文档 ID 取摘要前 16 字节；这只是本应用的身份设计，不表示与原应用兼容。

当前限制：OCR 源码尚未在 iOS 上运行；只能按所选 OCR 候选行建立摘录，不能在扫描页上直接拖动选择任意字词。旋转页的 PDF 选区与 OCR 坐标均暂不支持；Vision 图像到 PDF 的矩形映射仍需用 F2/F4 核对。摘录区域以运行时 PDFKit 标记显示，未写回 PDF，其视觉效果尚未验证；跨页选区未在设备上验证。源码已为应用目录设置 iOS 文件保护并排除系统备份，但尚未在设备上验证。备份只含摘录和笔记，恢复时仍需原 PDF；导出的 JSON 为明文，离开应用后不再受应用文件保护。请先使用 `tests/fixtures/` 的自制 PDF 测试，不要在未验证阶段导入敏感文件。

首次 Xcode 验证应记录 Xcode/Swift/iOS 版本和完整构建日志，运行工程 scheme 中的八项 iOS 单元测试（其中一项用 F2 实际调用 Vision），并按 `WORKFLOW_ACCEPTANCE.md` 先执行 A01–A04，再执行 OCR 的 A05–A08。macOS 上单独运行 `swift test --package-path ../StudyCore` 只验证数据包，不能代替 App 的构建和交互测试。

`.github/workflows/studyreader-ios.yml` 可手动触发，也可在测试分支推送时运行；它构建模拟器并运行测试，同时尝试生成未签名的设备 IPA。未签名 IPA 需要由用户使用合适工具签名后才能安装；构建结果以实际日志为准。
