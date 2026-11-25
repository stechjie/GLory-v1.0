# GLory iOS 27.1+ 动态窗口与 Duo 原生适配

## 改动范围

此补丁以现有 Godot 4.7 iOS 源归档为基线，仅改变 iOS 平台。
Android、Windows、macOS、无界面服务器不使用这些新路径。
既有 godot-4.7-ios-audio-recovery.patch 原样保留，先应用音频补丁再应用本补丁。
主源码目录和旧模板保留；工作区在 worktrees/ios27-duo-20261125。
编译选项 ios_min_version=15.0 同时应用到 C/C++、汇编和 Swift target，
与应用最低系统一致。早期 upstream 14.0 编译尝试已停止，保留日志，不用于交付。

原始引擎归档没有 .git，不能把文件夹名当作已经读取和验证的 Git HEAD。
构建 manifest 区分 expected_source_commit 与 source_commit_verification。

## 数据流

GDTViewController 在 iOS 27.1+ 创建 GDTAdaptiveContainerIOS，保留同一 GDTView
和 GDTKeyboardInputView。更早系统保留原有根 GDTView。

容器在 updateConstraints 查询公开 reservedRegionsOfKind:；UIKit 可因此在 regions
变化而 bounds 不变时更新约束。layoutSubviews 再读取当前本地 bounds、四边 safeAreaInsets、
displayScale、active division/occlusion。frame 已含 margins，不重复加边距。

纯 C++ godot_duo_geometry.h 寻找最大连续可用矩形：枚举横向边界并合并纵向遮挡，
支持负原点、横纵折痕、多个遮挡、无效数和空区域；结果向内对齐物理像素。
同面积候选优先保留上一 pane。没有硬编码设备尺寸或型号。

- 无 active division 时，游戏背景继续覆盖完整 bounds；HUD 从 DisplayServer
  get_display_safe_area() 获得 gameView 本地物理像素安全矩形。
- active division 时，将整个 GodotView 放到选定连续 pane；其他区域保留宿主背景。
- 真正没有可用区域时，frame 为零、禁用交互，不制造 1px 的假空间。
  已完成启动的引擎仍执行逻辑/网络迭代，DisplayServer 报告不能绘制。
- 渲染 layer、窗口尺寸、safe rect、触点 local coordinates 共享同一个子 view。
  点到像素先乘 scale 再取整，避免先截断 points 导致 1–2px 偏移。
- GL framebuffer 只在尺寸/scale 真正变化且非空时重建，保留既有画质参数。

## 输入与键盘合同

几何/scale 改变前取消现有触点。先清全部原生 touch slot，再发回调，
避免关闭 input accumulation 后同步派发产生重入重复取消。原生取消使用
InputEventScreenTouch(pressed=false, canceled=true)，Godot 已将 canceled 标记传递给
模拟鼠标事件。延迟到达的 touchesMoved / touchesEnded 不重新申请触点 ID。
GDScript 自定义拖拽处理仍须识别 canceled，只清理、不落子或提交。

键盘保留同一个隐藏 UITextView，不重写正在编辑的文本、选区或 marked text。
监听 Will/DidChangeFrame，按通知所属 UIScreen 的坐标空间转到当前 GodotView；
随宿主几何变化重新计算与底边相交且覆盖该 pane 宽度的遮挡像素高度。
隐藏后返回零。此高度接口不能表达浮动/分离键盘形状，不把浮动矩形伪造成全宽底部遮挡。
WebKit 补偿不适用于本项目的原生 Godot 输入路径，没有加入 WKWebView 特例。

## 诊断

启动环境 GLORY_IOS_GEOMETRY_LOG=1 会输出：
[GLORY_DUO] geometry=<generation> bounds=... game=... safe=... scale=... division=... regions=<实际保留区域矩形列表>

同一开关还输出 [GLORY_DUO] keyboard：editor 指针、firstResponder、选区索引、
marked text 起点/长度、文本长度与局部遮挡高度；只读，不改变输入状态。
这些证据用于核对折叠前后的同一原生编辑器与未提交合成。

不记录输入文本。字符串标记也用于产物门禁，配合模板 manifest 的补丁 SHA，
避免重新使用旧导出模板后仅主程序 SDK 升级、原生适配却回退。

## 几何验证

本轮原生模型测试已通过：

- 20 项命名边界用例；
- 500 组与独立像素网格穷举比较的最大面积检查及障碍输入反序检查；
- 1000 组带小数坐标的 2x/3x 严格包含与无交叠检查。

重跑（路径替换为当前隔离源码）：

    xcrun clang++ -std=c++17 -Wall -Wextra -Werror \
      -I /Volumes/repository/github/GLory/build/ios-duo-engine-source/godot-4.7 \
      deploy/engine/tests/ios_duo_geometry_test.cpp \
      -o /Volumes/repository/github/GLory/build/ios-duo-engine-source/geometry_test
    /Volumes/repository/github/GLory/build/ios-duo-engine-source/geometry_test

这证明纯几何边界，不等于真实 UIKit、键盘、业务或游戏已经验收。

## 构建与验收边界

五个实际修改的原生 Objective-C++ 对象已使用 Xcode 27.2 / iPhoneOS27.2 SDK
编译通过。完整 device/simulator 库、签名 IPA、Duo 实际姿态与输入的最终状态以本轮
构建日志和项目总报告为准；本文件不将未完成层级标为通过。

device 隔离源：build/ios-duo-engine-source/godot-4.7
simulator 隔离源：build/ios-duo-engine-source/godot-4.7-simulator
device 模板：build/ios-duo-templates/4.7.stable
旧模板：build/ios-audio-templates/4.7.stable（保留）

模拟器使用真实 iPhone Duo device type。至少验收 Closed、Open、Partially Open，
产品支持方向，页面/对局连续性，真实数字 7→78、中文 n→ni→你 合成期间开合，
HUD 和棋盘命中、拖拽取消、普通 iPhone 回归。实体 Duo 和实机性能单独报告。

## 官方接口依据

- https://developer.apple.com/documentation/uikit/uiviewreservedregion.md
- https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo.md
- https://developer.apple.com/documentation/uikit/uiresponder/keyboardwillchangeframenotification
- https://developer.apple.com/documentation/bundleresources/information-property-list/uirequiresfullscreenignoredstartingwithversion.md
- https://docs.godotengine.org/en/stable/classes/class_inputeventscreentouch.html
