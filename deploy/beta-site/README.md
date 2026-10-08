# 主播分享的统一测试入口

计划地址：`https://glorytd-api.duckdns.org/beta/`。**当前尚未部署，不可作为已上线链接分享。**

## 上线前条件

- iOS：在 App Store Connect 的外部测试群组添加可供外部测试的构建，通过所需 Beta 审核，启用公开链接，复制真实 `https://testflight.apple.com/join/...` 地址。
- Android：现有内测链接仅授权指定邮箱。需创建允许测试用户自助加入的 Google 群组，并在 Play Console 对应测试轨道授权该群组。内部测试最多 100 人；主播大规模招募应使用封闭测试轨道，并核实开发者账号和应用当前适用的发布条件。
- 将真实地址填入 config.json，验证陌生测试账号能加入后才设 `ready: true`。不得将只授权管理员邮箱的邀请当作公开招募入口。
- iPhone/iPad 自动前往 TestFlight；支持所有符合资格用户的 Android 开放测试可直接跳转。Google 群组模式保留“加入群组 → 接受邀请”两步，不能靠网页替用户推断群组成员资格。
- 微信、抖音等内置浏览器显示用系统浏览器打开的说明；桌面展示两端入口。`?manual=1` 可禁止自动跳转，便于查看页面。

## 校验与安装

```sh
node --test deploy/beta-site/routing.test.mjs
python3 deploy/beta-site/install.py --domain glorytd-api.duckdns.org --check-only
```

把此目录上传服务器后，先检查线上 `/etc/caddy/Caddyfile` 的站点与反向代理配置，再运行：

```sh
sudo python3 /已上传的目录/install.py --domain glorytd-api.duckdns.org
```

安装器要求两平台配置齐全；备份到 `/var/backups/glory/beta-site/时间戳`，只添加静态 `/beta/` 路由，执行 Caddy 配置验证和热重载，失败恢复原文件。战斗服务及账号后端不重启。

上线后验收：公网 HTTPS 页面、config.json、二维码返回 200；`/health` 保持正常；iPhone、iPad、Android、微信内置浏览器、桌面与返回浏览器场景均正确；陌生账号可完成测试群组/邀请/商店安装。部署校验不替代手机实际安装验收。

二维码固定指向入口，不编码平台短期链接。以后更新平台邀请只修改配置即可。此页面不收集用户邮箱，不实现邀请码或用户渠道归因。
