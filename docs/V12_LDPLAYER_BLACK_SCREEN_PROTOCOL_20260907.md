# V12 雷电黑屏复现协议（2026-09-07）

当前状态：诊断入口已建立，尚未取得雷电实例，不能声称已复现或已修复。

## 固定原则

- 先使用与手机复核完全相同 SHA-256 的 APK；不先改 renderer、内存、CPU 或 ABI。
- 保存雷电版本、Android 镜像、图形模式、宿主 GPU/驱动、ABI 列表、冷启动 30 秒完整 logcat 和黑屏截图。
- 通过 `GLORY_STARTUP` 判断停在引擎初始化前、数据加载前、首场景前还是已进入 UI；不能只凭黑色截图猜根因。
- 只有日志指出 Vulkan/OpenGL/ABI 初始化问题后，才制作 Mobile/Compatibility 或 ABI A/B 包；每个 A/B 包继续经过 APK 身份门禁。

## 运行

在 Windows PowerShell 5.1 中执行：

```powershell
powershell -ExecutionPolicy Bypass -File tools/ldplayer_black_screen_diagnostics.ps1 `
  -Serial <雷电 adb 序列号> `
  -Apk <与手机相同的 APK 路径>
```

脚本不会安装 APK，也不会更改模拟器配置。它会冷启动现有 `glory.beta001`，等待 30 秒，并在 `reports/ldplayer_<时间>` 保存：

- `summary.json`：APK hash、ABI、Android、EGL、启动标记和错误计数；
- `getprop.txt`、`surfaceflinger.txt`、`display.txt`、`package.txt`；
- `am_start.txt`、`logcat_full.txt`、`screen.png`；
- 可用时保存宿主 `dxdiag.txt`。

## 结果分流

1. `t0_trace_ready` 不出现：先查 ABI 转译、Activity/引擎与图形后端初始化。
2. `t0_trace_ready` 出现但 `data_registry_loaded` 不出现：查资源包、导入缓存与数据加载错误。
3. 数据已加载但仍黑屏：按后续 `GLORY_STARTUP` 标记、脚本错误和截图查首场景/UI/渲染。
4. Mobile 失败且日志指向图形后端时，才以相同提交、资源和场景导出 Compatibility A/B；手机 Mobile 路径仍需回归。
5. Windows 原生互通不并入“雷电能启动”的结论，另测协议版本、同服、掉线恢复和 replay SHA。

仍需用户提供或连接：雷电版本、Android 镜像版本、图形模式、实际 adb 序列号，以及已安装的同 hash APK。

