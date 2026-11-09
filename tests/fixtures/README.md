# 自制 PDF 验收材料

新增 F5/F6：`scripts/generate_layout_fixtures.py` 使用现有 PyMuPDF 绘制的两页复杂版面，分别为原生文字/矢量 Form 和扫描图像版。包含整图内部标签、双栏正文/图注、栏内图、两个独立图、公式、页眉页脚。`layout_expected.json` 是绘制规格中的人工预期框，不由检测算法生成。脚本重复生成的文件哈希一致；图像预览用于人工核验。它们是独立合成测试材料，不包含用户截图、私有 PDF 或原 IPA 资源，不能证明真实论文的识别准确率。

四份 PDF 由 `scripts/build_pdf_fixtures.py` 使用 Codex 预装的 Python PDF 运行环境生成，没有读取或复制原 IPA 内容。`manifest.json` 记录各文件 SHA-256、页数、文字层页码及预期语句。可用同一运行环境执行 `scripts/verify_pdf_fixtures.py` 复核结构和文字层；生成脚本需要 Windows 的 `C:\Windows\Fonts\msyh.ttc`，因此跨系统重建前应替换为获授权的等效字体。

| 文件 | 预期性质 | 对应验收 |
| --- | --- | --- |
| `F1_text_layer.pdf` | 两页可提取中英文文字；第一页有相邻两行 | A01–A04、A09 |
| `F2_image_only.pdf` | 一页图片，无可提取文字层 | A05、A06、A10 |
| `F3_corrupt.pdf` | 故意截断，不能正常读取 | A07 |
| `F4_mixed.pdf` | 第一页文字层，第二页图片 | A08 |

已用 Poppler 验证 F1 中英文可提取、F2 无文字层，并渲染检查 F1/F2 首页面显示。`pypdf`/`pdfplumber` 对该字体生成的中文返回乱码，不能作为中文文字层的单独判据；iOS PDFKit 的提取/选择效果仍需实测。图片页中的文字只是测试内容，不能说明 OCR 已实现或准确。四份材料均不含私有笔记或第三方应用资源。
