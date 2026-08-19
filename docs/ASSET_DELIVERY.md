# A2 资源交付与恢复

## 这套工件做什么

它不是 APK，也不是玩家运行的程序。它让 Git 只承载代码、小资源和可审计描述，
把大资源作为独立 ZIP 交付；新机器恢复前后都用 SHA-256 拒绝错包、损坏和篡改。

工程内 `assets/` 始终是唯一运行时位置。ZIP 只是运输工件，不能作为 Godot 资源根。

## 当前已验证版本（2026-08-19）

| 项目 | 值 |
| --- | --- |
| manifest schema | `2` |
| inventory SHA-256 | `5dabb3f546ee6ec0dd8491441ab32872afda3c4e2da46360e752e75e91fc508e` |
| 清单文件 | 2643 项，3115.5 MiB |
| Git 跟踪的清单资源 | 853 项 |
| ZIP 外置资源 | 1790 项 |
| ZIP 文件 | `glory-assets-5dabb3f546ee6ec0-a7733885bef50b62.zip` |
| ZIP 字节数 | 2,786,156,681 |
| ZIP SHA-256 | `a7733885bef50b6270591d2f044bd4b6b84a2ff33c035608b64aabf217c9fdda` |
| 远端存储 | 未配置；`storage_uri` 为空，本轮没有上传 |

版本关系：`assets.bundle.json` 指向一个确定 ZIP；bundle 与
`assets.manifest.json` 的 `inventory_sha256` 必须完全相同。
`generated_at` 不参与库存身份，因此同一批 path/size/content/class 在不同时间仍得到同一指纹。

## 文件职责

- `assets.manifest.json`：全部 2643 个资源的路径、大小、SHA-256、分类和引用摘要。
- `assets.bundle.json`：ZIP 文件名/哈希/大小、1790 个外置路径及对应 manifest 指纹。
- `.gitattributes`：让清单覆盖的 Godot 文本资源在 Windows/macOS/Linux 都保持 LF，避免 `core.autocrlf` 改变哈希。
- `tools/asset_delivery_check.tscn`：只读校验现有工程，失败时返回非零退出码。
- `tools/package_assets.ps1`：验证 manifest 和所有源文件后，生成固定顺序、固定时间戳的内容寻址 ZIP。
- `tools/restore_assets.ps1`：验证 bundle、ZIP 和每个文件，在临时目录解压并完成预检查后再补入工程。

## 打包

在 Godot/Git 工程根执行：

```powershell
.\tools\package_assets.ps1
```

如果 `git` 不在 `PATH`：

```powershell
.\tools\package_assets.ps1 -GitExecutable "C:\path\to\git.exe"
```

默认输出到工程同级的 `build\assets\`，并更新工程根的 `assets.bundle.json`。
脚本会先验证全部 manifest 条目；缺失、大小错误、哈希错误或 manifest 指纹错误都会停止打包。

## 新机器恢复

先克隆 Git 仓库，再取得与 `assets.bundle.json` 对应的 ZIP。可以把 ZIP 放在 bundle
描述文件旁或工程同级 `build\assets\`；也可以显式指定：

```powershell
.\tools\restore_assets.ps1 `
  -ArchivePath "D:\GloryArtifacts\glory-assets-5dabb3f546ee6ec0-a7733885bef50b62.zip" `
  -GodotConsole "C:\path\to\Godot_console.exe"
```

恢复脚本按以下顺序硬失败：

1. manifest/bundle schema 或库存指纹不一致；
2. ZIP SHA-256、条目数量或路径表不一致；
3. ZIP 内有绝对路径、`..` 路径穿越或 manifest 外文件；
4. 临时解压后的大小或 SHA-256 不一致；
5. 目标存在内容不同的文件（默认拒绝覆盖）；
6. 恢复后的 Godot 全量门禁不通过。

脚本不会删除现有资源。只有人工审查冲突后显式传
`-ReplaceMismatchedExternalAssets` 才允许替换 bundle 管理的冲突目标。

## 只读校验

快速校验允许使用 path/size/mtime 哈希缓存：

```powershell
godot --headless --path . res://tools/asset_delivery_check.tscn -- --strict-extras
```

交付、构建前必须使用全量哈希：

```powershell
godot --headless --path . res://tools/asset_delivery_check.tscn -- --full-hash --strict-extras
```

成功必须同时看到：

```text
ASSET_DELIVERY_RESULT status=PASS entries=2643 missing=0 size_mismatch=0 hash_mismatch=0 extras=0 ...
CHECK_RESULT name=asset_delivery status=PASS checked=2643 failures=0 allowed=0 stale=0
```

## 已完成的冷克隆验收

- Git 冷克隆没有 ZIP 时：退出码 1，精确报告 1790 个外置资源缺失，大小/哈希误报为 0。
- 从最终 ZIP 恢复：`copied=1790`，随后 2643 项全量校验通过。
- 删除 `.godot` 后首次完整导入：导入 1045 项，完成后 `extras=0`；水晶 FBX 不再产生未登记 `_5/_6` 文件。
- 单文件篡改：给 `fighting_music.mp3.import` 增加一行后，门禁精确报告 1 个 size mismatch、退出码 1；恢复原件后通过。
- 恢复后的既有门禁：`model_bounds` 44/44；`skel_check` 68 项、7 项限期豁免；`board_4x4_smoke` 62/62；`dep_scan` 726 项、1 项限期豁免。

首次导入仍会打印历史 `backups/` 重复 UID 和部分 FBX 内嵌贴图路径警告。这些是
E2/A5 的模型与备份治理事项；它们不表示 ZIP 少文件，也没有被 A2 静默豁免。

## 当前边界

- 本轮没有 Git commit、push 或对象存储上传；正式共享前必须先配置受控存储并填写 `storage_uri`。
- A4/Android 导出和设备回归按用户要求暂停：没有修改导出预设、构建 APK 或运行 ADB。
- 任何资源内容变更都必须重新生成 manifest 和 bundle，不能手改 SHA-256。
