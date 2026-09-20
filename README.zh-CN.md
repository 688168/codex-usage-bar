# Codex Usage Bar

一款轻量、原生的 macOS 菜单栏小工具，用于查看 Codex 剩余用量，并在有
reset 时进行确认后使用。

> 这是独立的社区项目，与 OpenAI 无隶属或官方背书关系。

## 功能

- 菜单栏直接显示 Codex 剩余百分比。
- 展开查看用量窗口、下一次恢复时间和账户套餐。
- 显示可用 reset 数量；没有时显示“当前没有可用 reset”。
- 真正消耗 reset 前必须手动确认。
- 最近一次手动 reset 的时间与结果只保存在当前 Mac。
- 每五分钟自动刷新。
- 使用本机已经登录的 Codex 账户，不读取或保存 ChatGPT Token。
- 使用 macOS 标准机制支持登录时自动启动。

## 安装条件

- macOS 13 Ventura 或更高版本。
- 已安装并登录 Codex/ChatGPT Mac App，或者通过 Homebrew 安装了 Codex CLI。
- Apple Command Line Tools；若未安装，运行 `xcode-select --install`。

## 一键安装

```bash
git clone https://github.com/688168/codex-usage-bar.git
cd codex-usage-bar
./scripts/install.sh
```

脚本会在本机编译应用、复制到 `/Applications/Codex Usage Bar.app` 并启动。
随后可以在小工具菜单中开启“登录时自动启动”。

你也可以直接把本仓库地址交给另一台 Mac 上的 Codex，让它克隆项目、运行
`./scripts/install.sh`、核验签名和自检结果，然后打开应用。

## 更新

```bash
cd codex-usage-bar
git pull --ff-only
./scripts/install.sh
```

## 只构建、不安装

```bash
./scripts/build.sh
open "dist/Codex Usage Bar.app"
```

项目使用 Objective-C/AppKit 和系统 Command Line Tools，不依赖第三方库，也
不要求安装完整 Xcode。

## 验证

离线自检：

```bash
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --self-test
```

只读账户诊断：

```bash
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --diagnose
```

诊断只读取账户、用量和 reset 数量，不会消耗 reset。

## 隐私与安全

- 身份验证由本机 Codex App Server 处理。
- 不读取、记录或保存 ChatGPT Token。
- 账户邮箱在显示前会被遮罩。
- 最近一次手动 reset 结果仅保存在当前 Mac，不会同步。
- 使用 reset 前始终要求明确确认。

当前社区构建采用临时签名，尚未经过 Apple 公证。正式公证版本发布前，推荐
从源码在本机编译。

## 卸载

先在应用菜单中关闭“登录时自动启动”，退出应用，再把
`/Applications/Codex Usage Bar.app` 移到废纸篓。

## 许可证

源代码使用 [MIT License](LICENSE)。第三方商标和图形说明见
[NOTICE.md](NOTICE.md)。
