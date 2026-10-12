# GLory 测试下载入口

固定地址：`https://glorytd-api.duckdns.org/beta/`。二维码始终编码此地址，中间使用游戏水晶图标。

- iPhone/iPad：保留现有 TestFlight 公开测试邀请；普通浏览器自动跳转，`?manual=1` 可查看完整页面。
- Android：显示“下载 Android APK”，点击后打开 Google Drive 文件页。无需测试群组或名单。Drive 文件必须允许“知道链接的任何人”只读下载；在无登录状态验证后，才将 `android.ready` 设置为 `true`。
- Android 不自动跳转，以便用户阅读安装说明。微信、抖音等内置浏览器提示使用系统浏览器。
- 配置只接受 HTTPS 的 TestFlight 邀请和 Google Drive 文件地址，拒绝任意外部跳转。

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

安装器备份 `/opt/glory/public/beta`、Caddy 配置，验证后热重载；失败则恢复。部署只涉及下载页面，不重启账号或战斗服务。上线验收应包含 HTTPS 页面、实际 Drive 无登录下载、TestFlight 入口、二维码识别及 `/health`。

2026-10-11 本地页面已改为 APK 下载流程；部署及公开分享状态以 `delivery/android-direct-20261011/status.json` 的验证结果为准，不能将本地修改当作已上线。

## 语言与反馈

页面依据浏览器首选语言（设备/系统语言）自动显示简体中文、繁体中文或英文。`zh-Hant` 与 TW/HK/MO 使用繁体，`zh-Hans` 优先使用简体；其余中文使用简体，非中文使用英文。所有状态、安装说明与按钮同步翻译。

反馈可提交给邀请主播，或点击官方 Discord 反馈群：https://discord.gg/vsVDcrwft 。
