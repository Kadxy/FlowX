# FlowX

[English](README.md)

一个极简的 macOS 菜单栏歌词应用，专为 **Apple Music** 设计，支持实时卡拉OK逐词高亮，零 CPU 渲染。

<p>
  <img src="assets/karaoke-zh-light.gif" height="40" />
  <img src="assets/karaoke-zh-dark.gif" height="40" />
</p>

## 功能

- **实时同步歌词** — TTML 歌词直接显示在菜单栏，与播放完美同步
- **卡拉OK效果** — 逐词高亮动画（可关闭，切换为普通滚动）
- **悬停播放控制** — 鼠标悬停时显示 上一曲 / 播放·暂停 / 下一曲 按钮
- **智能间奏检测** — 在前奏和间奏期间显示动态 ♪ 音符
- **边缘淡化** — 歌词两端可配置渐变淡化效果
- **宽度可调** — 歌词区域宽度 120 pt 到 320 pt 自由调节
- **Apple Music API 获取 TTML 歌词** — 支持本地磁盘缓存
- **自动深色/浅色模式** — 无缝跟随系统外观
- **10 种语言** — English、简体中文、繁體中文、Deutsch、Español、Français、日本語、한국어、Português (Brasil)、Русский

## 系统要求

- macOS 26.0+
- Apple Music

## 安装

从 [Releases](https://github.com/kadxy/FlowX/releases) 下载最新的 `FlowX-vX.X.X.dmg`，打开后将 `FlowX.app` 拖入 `Applications`。

> 应用未经公证，下载后需执行以下命令移除隔离属性：
>
> ```bash
> xattr -cr /Applications/FlowX.app
> ```

## 配置

从菜单栏 FlowX 图标打开 **设置**（⌘,）。

| 区域 | 选项 | 说明 |
| --- | --- | --- |
| Apple Music API | User Token | 从 Apple Music 网页播放器粘贴 `media-user-token`（浏览器开发者工具获取） |
| Apple Music API | Storefront | 选择你的 Apple Music 地区（默认根据系统区域自动检测） |
| Menu Bar Lyrics | Lyrics Width | 调整歌词显示宽度（120–320 pt） |
| Menu Bar Lyrics | Edge Fade | 两端渐变淡化宽度（0–60 pt） |
| Menu Bar Lyrics | Karaoke Effect | 开启/关闭逐词高亮 |
| General | Language | UI 语言（默认跟随系统） |

## 技术栈

- Swift / SwiftUI + AppKit
- ScriptingBridge — Apple Music 播放控制
- Apple Music API — TTML 歌词获取
- CALayer + CAAnimation — 零 CPU 菜单栏渲染
- MediaRemote.framework（通过 osascript）— 获取歌曲 Catalog ID

## 从源码构建

```bash
git clone https://github.com/kadxy/FlowX.git
cd FlowX
open FlowX.xcodeproj
```

使用 Xcode 16+（macOS 14.0 部署目标）编译运行。需关闭沙盒。

## 许可证

[GPL-3.0](LICENSE)
