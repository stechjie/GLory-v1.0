# 工作区构建与同步工具

唯一源码位于仓库 `tools/workspace`，工作区 `GLory/tools` 是指向此目录的快捷链接。推荐目录：`GLory/GLory-v1.0`。从任意当前目录调用均可；双击本目录 `.command` 即可同步或构建。

- `sync_res.sh`：下载 Drive 资源到工作区 `res/assets`，校验同名文件与本地版本，保留本地较新资源。
- `build_apk.sh --sync`：同步后合并资源，在 `build/android-work` 隔离构建。
- `build_ipa.sh --update`：同步后构建 IPA；签名配置仍使用本机私有目录。
- `release_testflight.sh`：使用本机账号配置提交内部测试；测试说明读取工作区 `docs/TestFlight测试内容.txt`。

新机器在工作区执行：`ln -s GLory-v1.0/tools/workspace tools`。签名文件、密钥、构建缓存及本地测试说明不提交 Git。Python 需要 3.10+；资源同步入口会建立本地虚拟环境。

回归测试：在工作区执行 `.glory-tools/venv/bin/python -m unittest discover -s tools -p 'test_glory*.py'`。
