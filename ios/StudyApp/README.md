# StudyReader：PDF 与 OCR 学习测试 App

独立 SwiftUI / PDFKit / Vision 实现，不包含第三方应用的代码、模型或资源。支持 iPhone/iPad，最低 iOS 18。

## 使用

导入 PDF 后，可选择已有文字层并建立摘录。扫描页点“识别本页”，在页面预览中选择识别出的文字范围，核对或修改文字后建立摘录、写笔记。识别设置提供准确/速度优先、语言和语言纠错选项。OCR 校正前原文和页面矩形会随摘录保存，便于核对。

文字区域来自 Vision 的真实范围框；准确模式可能给一个词中的多个字符返回同一框，此时按整个词选择，不虚构细分字符框。缺少范围框时会注明整行选择。保留原识别结果顺序，不声称解决复杂多栏阅读顺序。

摘录列表可回到 PDF 来源位置。“文件”菜单可导出明文 JSON 备份或合并恢复。备份包含摘录、识别原文和笔记，不包含 PDF；恢复后需重新导入同一 PDF。PDF 原文件保持不变，阅读时高亮由保存的来源矩形重建。

## 构建与测试

在 macOS 的 Xcode 中打开 `StudyReader.xcodeproj`，运行共享 scheme `StudyReader`。依赖只有系统框架和本仓库 `../StudyCore` Swift Package。

运行 `swift test --package-path ../StudyCore` 验证数据包。App 测试使用 `xcodebuild -project StudyReader.xcodeproj -scheme StudyReader -destination 'platform=iOS Simulator,id=<available-device-uuid>,arch=arm64' ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test`。

测试材料为仓库自制的中英文 PDF。验证覆盖文字层选区、文件恢复、OCR 坐标、相同词框合并、Unicode 范围、缺失几何、跨行/分离范围、校正前文字保留和实际 Vision 扫描页选词后保存读回。测试源码存在不代表已运行，以对应提交的 Actions 日志为准。

`.github/workflows/studyreader-ios.yml` 在测试分支推送后运行。StudyCore 与 `StudyReaderTests` 单元/集成测试通过后才构建设备包，产物包含 `StudyReader-unsigned.ipa` 和记录源码提交、版本、Xcode、SHA-256 的 `build-info.json`。打包后由使用者在自己的设备上实际测试，不能把核心测试通过当作全部交互已通过。

界面自动化独立保留：手动运行工作流时勾选 `run_ui_tests`，会额外运行 `StudyReaderUITests` 并导出 `StudyReader-optional-UI-results`。该任务失败会如实显示失败，但不阻止核心测试通过后的 IPA 打包；默认推送不运行它。已有 UI 自动化在滚动和重开控件查询中出现失败，完整界面流程仍待手动验证。

## 当前边界

- IPA 未签名，安装前需使用自己的开发团队或合适的签名方式；没有提供签名凭据，也未宣称真机安装成功。
- 旋转 PDF 页的文字选择和 OCR 坐标当前明确拒绝，避免错误定位。
- OCR 框是识别器提供的定位提示，不保证精确贴合每一个字符；复杂版面与低质量扫描仍须人工核对。
- 尚未证明全部 UI 操作、文件保护、跨页交互和真机性能。模拟器的合成材料测试不等于任意文档准确率或其他应用的功能等价。
- 本 App 不调用外部 OCR 服务；导入 PDF 和笔记保存在本地，应用目录排除系统备份。主动导出的 JSON 离开应用后应由用户妥善保管。
