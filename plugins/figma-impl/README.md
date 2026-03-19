# figma-impl

Claude Code 插件，用于从 Figma 设计稿批量实现 React 组件，并通过 Chrome DevTools 自动进行视觉验证。

## 功能概述

1. 你提供一组功能列表和对应的 Figma 设计稿 URL
2. 插件自动创建结构化任务列表，分析任务间的依赖关系
3. Harness 脚本循环调用 Claude Code，每轮会话实现一个功能
4. 每次实现都会通过 Chrome DevTools 截图与 Figma 设计稿进行视觉对比验证
5. 只有完美还原才会通过，否则自动修复并重新验证

## 前置条件

- 已安装 [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- 已安装 [jq](https://jqlang.github.io/jq/)（`brew install jq`）
- 已安装 Figma 桌面客户端并配置 Figma MCP 服务（用于读取设计稿，安装方式见下方）
- 已配置 Chrome DevTools MCP 服务（用于视觉验证）

### 安装 Figma MCP 服务

```bash
# 1. 安装 Figma 桌面客户端
brew install --cask figma

# 2. 添加官方插件市场
claude plugin marketplace add anthropics/claude-plugins-official

# 3. 安装 Figma MCP 插件
claude plugin install figma@claude-plugins-official
```

## 使用方法

### 第一步：初始化环境

```
/figma-impl-init
```

这会将 harness 脚本复制到项目根目录并创建配置文件，过程中会询问你的开发服务器信息。

### 第二步：创建任务

```
/figma-impl-plan
功能1: 导航栏组件, figma设计稿: https://figma.com/design/abc123/MyApp?node-id=1-2
功能2: 用户头像, figma设计稿: https://figma.com/design/abc123/MyApp?node-id=3-4
功能3: 登录页面, figma设计稿: https://figma.com/design/abc123/MyApp?node-id=5-6
```

插件会：
- 解析你的输入
- 自动分析依赖关系（例如：登录页面依赖头像组件）
- 创建 `.claude/figma-tasks.json` 任务列表

### 第三步：执行

```bash
./run-figma-impl.sh
```

Harness 脚本会：
- 自动启动开发服务器
- 按依赖顺序逐个执行任务，每个任务一个独立的 Claude 会话（全新上下文）
- 如果存在历史进度，显示交互式菜单供选择（继续/重置/重试失败）
- 随时可按 `Ctrl+C` 中断，进度自动保存

### Harness 命令

```bash
./run-figma-impl.sh                    # 执行所有任务
./run-figma-impl.sh --status           # 查看任务状态
./run-figma-impl.sh --dry-run          # 预览执行计划
./run-figma-impl.sh --reset <id>       # 重置指定任务
./run-figma-impl.sh --reset-all-failed # 重置所有失败任务
```

## 配置

编辑 `.claude/figma-impl-config.json`：

```json
{
  "maxRetries": 5,
  "devServerCommand": "npm run dev",
  "devServerUrl": "http://localhost:3000",
  "devServerPort": "3000",
  "screenshotWaitMs": 3000,
  "viewportWidth": 1440,
  "viewportHeight": 900,
  "sessionTimeout": 600
}
```

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `maxRetries` | 单个任务视觉验证最大重试次数 | `5` |
| `devServerCommand` | 开发服务器启动命令 | `""` |
| `devServerUrl` | 开发服务器 URL，用于 Chrome 导航 | `""` |
| `devServerPort` | 开发服务器端口 | `""` |
| `screenshotWaitMs` | 截图前等待时间（毫秒） | `3000` |
| `viewportWidth` | Chrome 截图视口宽度 | `1440` |
| `viewportHeight` | Chrome 截图视口高度 | `900` |
| `sessionTimeout` | 单个任务最大执行时间（秒） | `600` |

## 工作原理

基于 Anthropic 的 [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) 设计理念。

### 架构

```
run-figma-impl.sh (harness 循环)
  ├── 启动 dev server
  └── claude 会话 1: 实现任务 A
       ├── 读取状态文件
       ├── Figma MCP → 获取设计上下文 + 截图
       ├── 实现代码
       ├── Chrome MCP → 设置视口 + 截取实现截图
       ├── 对比验证 → 通过/失败
       └── 写入状态文件 + git commit
  └── claude 会话 2: 实现任务 B
       └── (全新上下文，从文件读取状态)
  └── ...
  └── 关闭 dev server
```

### 状态文件

| 文件 | 用途 |
|------|------|
| `.claude/figma-tasks.json` | 任务列表（状态、依赖关系、重试次数等） |
| `.claude/figma-progress.md` | 可读的执行日志 |
| `.claude/figma-impl-config.json` | 配置文件 |
| Git 历史 | 检查点与回滚 |

### 视觉验证清单

每次实现都会与 Figma 设计稿逐项对比：

- 布局结构（元素位置、flex/grid）
- 间距（padding、margin、gap）
- 颜色（背景色、文字色、边框色）
- 字体（字号、字重、行高）
- 圆角（border-radius）
- 阴影（box-shadow）
- 图标和图片
- 响应式表现

## License

MIT
