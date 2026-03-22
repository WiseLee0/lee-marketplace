---
name: figma-impl-init
description: |
  初始化 figma-impl 插件环境。将 harness 脚本复制到项目根目录，创建默认配置文件。
  触发场景：用户说"figma-impl init"、"setup figma-impl"、"初始化 figma-impl"、"安装 figma-impl 脚本"、提到 figma-impl-init。
user-invocable: true
---

# Figma Impl — 环境初始化

将 figma-impl harness 脚本安装到当前项目，并创建默认配置。

## 执行步骤

### 0. 清理历史文件

删除之前的任务和进度文件，确保从干净状态开始：

```bash
rm -f .claude/figma-tasks.json
rm -f .claude/figma-tasks.json.tmp
rm -f .claude/figma-progress.md
```

如果这些文件存在，先告知用户"检测到历史任务文件，已清理"。

### 1. 复制 harness 脚本

将插件内的 `scripts/run-figma-impl.sh` 复制到项目根目录：

```bash
cp "${CLAUDE_PLUGIN_ROOT}/scripts/run-figma-impl.sh" ./run-figma-impl.sh
chmod +x ./run-figma-impl.sh
```

如果 `${CLAUDE_PLUGIN_ROOT}` 不可用，提示用户从插件安装目录手动复制。

### 2. 创建配置文件

如果 `.claude/figma-impl-config.json` 不存在，创建默认配置：

```json
{
  "maxRetries": 5,
  "devServerCommand": "",
  "devServerUrl": "",
  "devServerPort": "",
  "screenshotWaitMs": 10000,
  "verifyThreshold": 80,
  "reviewThreshold": 80,
  "sessionTimeout": 600
}
```

### 3. 询问用户配置

向用户询问以下信息并写入配置文件：

1. **devServerCommand** — 开发服务器启动命令（如 `npm run dev`、`pnpm dev`）
2. **devServerUrl** — 开发服务器地址（如 `http://localhost:3000`）
3. **devServerPort** — 端口号（如 `3000`）
4. **maxRetries** — 失败重试上限（默认 5）
5. **sessionTimeout** — 单个任务的最大执行时间，单位秒（默认 600）

### 4. 输出结果

```
figma-impl 环境初始化完成！

已创建:
  ./run-figma-impl.sh              — harness 执行脚本
  .claude/figma-impl-config.json   — 配置文件

下一步:
  1. 在 Claude Code 中运行 /figma-impl-plan 创建任务列表
  2. 运行 ./run-figma-impl.sh 开始自动执行
```
