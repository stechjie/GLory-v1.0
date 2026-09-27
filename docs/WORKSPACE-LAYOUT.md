# 工作区目录与资源同步

2026-09-27 整理后的目录：

| 目录 | 用途 |
| --- | --- |
| `GLory-v1.0/` | GitHub main 源码和 Godot 工程，打开此处 project.godot |
| `tools/` | 快捷链接，实际源码为 `GLory-v1.0/tools/workspace/`；双击同步、APK、IPA、TestFlight 入口均在这里 |
| `res/assets/` | Drive 下载与合并资源区，不是另一个 Godot 工程 |
| `GLory-v1.0/assets/` | Godot 的 res://assets，运行必需，不可整目录删除 |
| `docs/` | 本机发布、安装说明及协作资料 |
| `GLory-v1.0/docs/` | 随源码共享的开发文档；数值表在 balance/ |
| `build/` | APK、IPA、服务端构建输出、构建缓存与日志 |
| `delivery/` | 按日期保存的云盘交付包、清单和校验结果 |
| `bak/cleanup-20260927/` | 旧 review、历史审查、临时产物和本次资源替换前副本；moves.json 记录迁移路径 |
| `worktrees/` | Git 工作树，不能作为普通残留目录随意搬动 |
| `.glory-sync/`、`.glory-tools/` | 同步状态、断点信息及工具环境 |
| `ios-signing-20260913/` | 本机已有私有签名配置，保持路径供构建使用，不上传 |

Windows 服务端打包入口已移动到 `GLory-v1.0/tools/make_server_zip.bat`；PowerShell 默认从上一级工程目录取源码，产物仍写工程根目录。

历史审查图与运行日志已归档。帧时间检查实际使用的两个 JSON 基线保留在 `tools/testdata/`；近期协作者 QA 脚本保留在 `tools/qa_history/`。检查输出统一写入忽略的 `reports/`。

资源同步按 SHA-256 比较。内容不同且时间可靠时选较新版本；时间相同或未知时不盲目覆盖。云端重名文件内容一致时稳定选择一个，内容不同且无法判断版本则停止并报告。构建仍在独立 staging 目录合并资源。

GitHub 只提交源码、工具、文档与既有必要资源例外。Drive 上传资源增量包及完整哈希清单，不上传 bak、缓存、证书和整个旧工程。未来构建后必须运行 `tools/package_content_check.py` 检查 APK/IPA 内容边界。
