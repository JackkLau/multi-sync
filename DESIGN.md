---
version: alpha
name: MultiSync
description: 原生多设备文件收发工作台，以接收确认和真实任务状态为中心。
colors:
  primary: "#096C74"
  ink: "#183238"
  muted: "#54696E"
  canvas: "#F4F8F9"
  line: "#D6E3E5"
typography:
  display:
    fontFamily: "SF Pro Rounded, PingFang SC, system-ui, sans-serif"
    fontSize: "27px"
  body:
    fontFamily: "SF Pro, PingFang SC, system-ui, sans-serif"
  utility:
    fontFamily: "SF Mono, ui-monospace, monospace"
rounded:
  card: "14px"
spacing:
  section: "20px"
components:
  surface:
    background: "#FFFFFF"
    borderRadius: "14px"
---

# MultiSync Design System

## Overview

这是个人混合设备用户的文件收发工具，开发预览提供简体中文 macOS、Windows、Android 和 iPhone/iPad 原生客户端。
视觉参考是桌面上的文件收发托盘：发送与接收分开，文件本身、对方确认和送达凭据占据主要位置。
标志性元素是每份文件的“状态回执”：文件名、已确认字节、明确状态、可恢复操作始终在同一块表面内。
避免社交聊天窗口、云盘营销页、装饰性的虚假设备及伪造历史记录。

## Colors

蓝绿色只用于主要动作和成功图标。深墨色为正文，灰青色为说明，浅蓝灰底色区分工作区和侧栏。
首版明确固定浅色；错误使用系统红色，同时提供文字原因。状态不能仅依赖颜色。

## Typography

大标题使用系统圆体，正文和中文采用系统字体回退。路径使用等宽字体，进度数字使用等宽数字。
文件名允许两行并保留完整路径提示；错误原因不截断。使用系统字号语义适配辅助功能。

## Layout

210 pt 固定侧栏，右侧单个纵向滚动区域。内容最大宽 920 pt，窗口最小 800 × 620 pt。
右侧工作区间距 22 pt，Surface 内部间距使用 Theme.gap=20 pt。双工作流共享相同组件。
Windows 采用发送/接收双页和原生滚动区，最小窗口 860 × 620；Android 手机为纵向单栏，720 dp 及以上显示侧边导航；iPhone/iPad 采用系统 TabView，内容最大宽 780 pt，按钮适配触控。

## Elevation & Depth

采用白色表面与细边界，不用投影叠加层级。文件与目录选择使用各平台原生选择器；移动端接收保存到应用管理空间，提供打开/导出。

## Shapes

Surface 圆角 14 pt，按钮、输入框采用 macOS 原生外观和系统焦点。

## Components

运行时颜色、圆角与组内间距由 `apps/macos/Sources/MultiSync/Theme.swift` 统一持有；本文镜像并解释这些值（Model B）。
映射：primary→Theme.accent；ink/muted/canvas/line→同名属性；rounded.card→Theme.radius；spacing.section→Theme.gap。
平台适配器：iOS `Sources/ContentView.swift` 的 MobileTheme/Surface，Android `MainActivity.kt` 的 MaterialTheme/SurfaceCard，Windows `MainWindow.cs` 的 Accent/Ink/Canvas 与 Text/Row/ActionButton。它们镜像本文颜色，采用各自平台字体、触控尺寸和原生状态控件；iOS 触控表面圆角允许 16 pt。
Surface 用于收发设置和任务回执；Button/ProgressView/SecureField 为系统语义组件。
接收二维码采用黑白原始像素、至少四模块留白，不放徽标或覆盖装饰；在白色表面上完整显示。扫码窗口复用原生 Sheet，提供关闭入口和明确摄像头状态。
Apple 平台使用 SF Symbols；Android 使用原生 Material 导航与中文标签，Windows 采用文字动作。图标按钮均有中文辅助名称，桌面提供适用的 help。
无装饰动画；进度条只表示已确认字节，完成前显示校验状态。持久提示可关闭，任务错误保留在具体任务中。
日期无独立输入；容量格式使用系统 ByteCountFormatter。语言暂不提供切换。

## Do's and Don'ts

- 展示真实错误和后续操作；无引擎时明确显示未构建并禁用收发。
- 发送、接收共享 Surface、状态标签与进度布局，保留系统键盘操作。
- 不把已发送字节等同于已保存文件；只有接收方完成校验和提交才显示送达。
- 不展示模拟设备、模拟历史，不把模拟器构建或回环测试描述成六类物理设备全部验收。
