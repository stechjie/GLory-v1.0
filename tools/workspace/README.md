# 工作区构建与同步工具

唯一源码位于仓库 `tools/workspace`，工作区 `GLory/tools` 是指向此目录的快捷链接。推荐目录：`GLory/GLory-v1.0`。从任意当前目录调用均可；双击本目录 `.command` 即可同步或构建。

- `sync_res.sh`：下载 Drive 资源到工作区 `res/assets`，校验同名文件与本地版本，保留本地较新资源。
- `build_apk.sh --sync`：同步后合并资源，在 `build/android-work` 隔离构建。
- `build_ipa.sh --update`：同步后构建 IPA；签名配置仍使用本机私有目录。
- `release_testflight.sh`：使用本机账号配置提交内部测试；测试说明读取工作区 `docs/TestFlight测试内容.txt`。

新机器在工作区执行：`ln -s GLory-v1.0/tools/workspace tools`。签名文件、密钥、构建缓存及本地测试说明不提交 Git。Python 需要 3.10+；资源同步入口会建立本地虚拟环境。

回归测试：在工作区执行 `.glory-tools/venv/bin/python -m unittest discover -s tools -p 'test_glory*.py'`。

## 检查与调用

脚本通过自身所在目录寻找相邻工具；直接运行 `GLory-v1.0/tools/workspace` 内的入口也可以，不依赖外层 `tools` 快捷链接。`.command` 支持透传参数；在非交互终端中保留退出码，不等待回车或打开 Finder。

在 `GLory` 工作区执行以下只读预检，不会构建、上传或部署：

```bash
./tools/build_apk.sh --sync --check
./tools/build_ipa.sh --update --check
./tools/release_testflight.sh --check
```

资源扫描使用 `./tools/sync_res.sh --dry-run`；它会访问 Drive 并保存扫描清单，但不覆盖资源。当前源为共享目录 `1xjn5Hpa4AzSS8v7hgECEZstHb3dG6m11` 下的 `glory`（`19WnebPCTVXxxjY6pfJjsrAVyVJ0P9mXl`），只同步 `assets` 和资源清单，不下载该目录的旧代码或缓存。同步入口是云端到 `res` 的下载工具，不会自动反向上传；打包时再按已有版本规则合并项目与 `res`。

TestFlight 自动上传必须先由账号持有人配置 App Store Connect 团队 API Key。缺少配置时脚本会明确退出，不能仅凭浏览器或 Transporter 已登录判断自动发布可用。配置入口为 `./tools/release_testflight.sh --setup`，本机说明位于 `docs/TestFlight一键发布.md`；密钥必须保存在项目外。

预检通过只说明工具、资源路径和签名配置可用；实际 APK/IPA 导出以及 Apple 处理结果仍以对应构建或发布日志为准。
