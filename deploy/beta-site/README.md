# GLory 测试下载入口

固定地址：`https://glorytd-api.duckdns.org/beta/`。二维码始终编码此地址，中间使用游戏水晶图标。

- iPhone/iPad：保留现有 TestFlight 公开测试邀请；普通浏览器自动跳转，`?manual=1` 可查看完整页面。
- Android：采用 Google 群组＋Google Play 封闭测试，配置模式为 `play_closed`。页面固定提供“① 加入群组”和“② 加入测试”两步操作。
- 未加入群组的用户先打开 `https://groups.google.com/g/glorygame/about` 自助加入；群组成员使用同一 Google 账号报名 Play 封闭测试，再安装游戏，无需逐个添加邮箱。
- 曾参加内部测试的用户需先退出内部测试，再报名封闭测试。
- Android 保留引导页供用户阅读步骤；微信、抖音等内置浏览器提示使用系统浏览器。
- 封闭版本尚未正式可下载时保持 `android.ready: false`，群组按钮可用；取得正式报名链接后测试按钮也可用，并说明下载需等待审核和发布。Google Play 控制实际报名和下载资格，审核通过后链接继续沿用。送审成功与公开下载可用分别记录。
- 配置只接受 HTTPS 的 TestFlight、Google Groups 与 Google Play 封闭测试地址；不提供 Drive 共享 APK 或内部测试的回退入口。

## 校验和部署

```sh
node --test deploy/beta-site/*.test.mjs
python3 deploy/beta-site/install.py --domain glorytd-api.duckdns.org --check-only
```

尚未完成公开下载验证时保持 `android.ready: false`。仅在有意发布等待状态时使用 `--allow-pending`。

将本目录复制到服务器后运行：

```sh
sudo python3 /已上传目录/install.py --domain glorytd-api.duckdns.org
```

安装器备份 `/opt/glory/public/beta`、Caddy 配置，验证后热重载；失败则恢复。部署只涉及下载页面，不重启账号或战斗服务。上线验收应包含 HTTPS 页面、Google 群组自助加入、Play 封闭测试邀请与群组成员访问、TestFlight 入口、二维码识别及 `/health`。

2026-10-18 升级为群组＋封闭测试，版本 0.0.24 (37)。二维码继续指向固定官网地址；审核、发布和公网回读证据位于外层 `delivery/google-play-closed-20261018/`。以后更新 Android 版本时沿用 Play 测试邀请，不回填 Drive 共享地址。

## 语言与反馈

页面依据浏览器首选语言（设备/系统语言）自动显示简体中文、繁体中文或英文。`zh-Hant` 与 TW/HK/MO 使用繁体，`zh-Hans` 优先使用简体；其余中文使用简体，非中文使用英文。所有状态、安装说明与按钮同步翻译。

反馈可提交给邀请主播，或点击官方 Discord 反馈群：https://discord.gg/vsVDcrwft 。
