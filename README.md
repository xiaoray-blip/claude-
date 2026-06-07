# Claude Code 配置工具

一个 Windows 上的可视化小工具：用图形界面管理多套 Claude Code 配置，
一键把"启动按钮"发送到桌面，双击即带着对应的环境变量进入 `claude`。
零额外依赖（只用 Windows 自带的 PowerShell），整个文件夹拷到任何 Windows 电脑都能用。

## 使用方法

1. 双击 **`打开配置工具.bat`** 打开界面。
2. 左侧是配置列表，右侧编辑当前配置：
   - **配置名称**：随意起名，会作为桌面按钮的名字。
   - **API 地址 (Base URL)**：中转/代理地址；用官方接口可留空。
   - **认证方式**：代理/中转一般选 `Auth Token`，官方密钥选 `API Key`。
   - **密钥 / Key**：你的 token 或 API key（点"显示"可查看）。
   - **模型 / 快速模型**：可选，对应 `ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL`。
   - **启动目录**：可选，启动 claude 时进入的目录。
   - **额外环境变量**：可选，每行一个 `KEY=VALUE`。
3. 点 **保存配置**。
4. 点 **发送到桌面** —— 桌面会出现一个 `Claude - 配置名` 的快捷方式。
5. 双击桌面快捷方式即可启动。

也可以点 **一键生成全部** 把所有配置都发送到桌面。

## 按钮说明

- **新建 / 复制 / 删除**：管理多套配置。
- **环境检测**：检查本机的 Node.js / npm / claude 是否就绪。
- **测试连接**：用当前配置向接口发一个最小请求，验证地址和密钥是否可用。

## 自动适配环境

桌面按钮在运行时会自动定位 `claude`（先查 PATH，再查 npm 全局目录），
所以换一台电脑也不用改路径。如果电脑上还没装 claude，按钮会提示：

```
npm install -g @anthropic-ai/claude-code
```

（前提是先装好 [Node.js](https://nodejs.org)。）

## 拷到别的电脑

直接把整个 `ClaudeLauncher` 文件夹复制过去，双击 `打开配置工具.bat` 即可。
你的配置存在 `data\profiles.json`，启动脚本在 `launchers\` 里，都会跟着走。
到了新电脑重新点一次"发送到桌面"即可生成那台电脑的桌面按钮。

## 文件结构

```
ClaudeLauncher\
├─ 打开配置工具.bat        双击入口
├─ ClaudeConfigTool.ps1    主程序
├─ README.md               本说明
├─ data\profiles.json      你的配置（自动生成）
└─ launchers\*.cmd         各配置的启动脚本（自动生成）
```

> 提示：每套配置的环境变量只作用在它自己的启动脚本里，互不影响，也不会改动
> `~/.claude/settings.json` 的全局设置。
