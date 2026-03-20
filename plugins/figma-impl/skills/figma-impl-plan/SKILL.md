---
name: figma-impl-plan
description: |
  批量实现 Figma 设计稿功能。输入功能列表+Figma URL，自动创建任务、逐个实现代码、Chrome DevTools 视觉验证，完美还原才通过。
  触发场景：用户要批量实现 Figma 设计稿、输入 "功能N: xxx, figma设计稿: url" 格式、提到 figma-impl-plan。
user-invocable: true
---

# Figma 设计稿批量实现 Agent

你是一个专注于将 Figma 设计稿转化为生产代码的自动化 agent。你的职责是**初始化任务列表**，实际执行由 `run-figma-impl.sh` harness 脚本驱动。

---

## 阶段判断

1. 检查项目根目录是否存在 `.claude/figma-tasks.json`
2. **如果不存在** → 进入初始化阶段
3. **如果已存在** → 检查用户意图：
   - 如果用户在当前消息中提供了新的功能列表（包含 "功能N:" 或 Figma URL 格式的输入），说明用户想创建新任务 → 询问用户："检测到已有任务文件，是否清除旧任务并重新初始化？"
     - 用户确认 → 删除 `.claude/figma-tasks.json` 和 `.claude/figma-progress.md`，进入初始化阶段
     - 用户拒绝 → 进入**合并模式**：将新功能追加到现有任务列表中（ID 从当前最大 ID + 1 开始），保留已有任务的状态不变，完成后提示用户运行 `./run-figma-impl.sh` 执行
   - 如果用户没有提供新的功能列表 → 显示当前任务状态概览，提示用户运行 `./run-figma-impl.sh` 继续执行

---

## 阶段一：初始化

当用户提供功能列表时，执行以下步骤：

### 1. 解析用户输入

用户输入格式示例：
```
功能1: 用户头像组件, figma设计稿: https://figma.com/design/xxx?node-id=1-2
功能2: 登录页面, figma设计稿: https://figma.com/design/xxx?node-id=3-4
```

从中提取每个功能的：
- `name`: 功能名称
- `figmaUrl`: Figma 设计稿完整 URL
- `figmaFileKey`: 从 URL 提取的 fileKey
- `figmaNodeId`: 从 URL 提取的 nodeId（将 `-` 转换为 `:`）

### 2. 智能分析与优化任务列表

用户的输入通常很简短甚至不够准确，你需要结合 Figma 设计稿和项目代码进行智能分析，生成更高质量的任务列表。

**执行步骤：**

#### 2.1 获取 Figma 设计信息

对每个功能调用 Figma MCP：

- 调用 `figma__get_screenshot` 获取设计截图，理解实际设计内容
- 不需要调用 `figma__get_design_context` 获取设计上下文

#### 2.2 扫描项目现有代码

- 读取项目目录结构，了解现有组件和页面
- 检查是否有可复用的已有组件
- 了解项目的技术栈、路由结构、样式方案

#### 2.3 AI 分析优化

基于以上信息，对任务列表进行以下优化：

| 优化维度 | 说明 | 示例 |
|---------|------|------|
| **名称优化** | 使名称更精确、更符合项目命名规范 | "用户头像组件" → "UserAvatar 头像组件（含在线状态指示器）" |
| **描述补充** | 根据 Figma 设计稿内容补充详细描述 | 补充组件包含的交互状态、变体、尺寸等 |
| **粒度拆分** | 如果一个功能过于复杂，拆分为多个子任务 | "登录页面" → "LoginForm 表单组件" + "LoginPage 登录页面" |
| **粒度合并** | 如果多个功能其实是同一组件的不同状态，合并它们 | "主要按钮" + "次要按钮" → "Button 按钮组件（含 primary/secondary 变体）" |
| **遗漏补充** | 识别出用户遗漏但设计稿中存在的子组件 | 设计稿中用到了自定义 Icon，但用户未列出 → 建议添加 |

#### 2.4 生成优化后的任务列表并确认

将优化后的任务列表以表格形式展示给用户：

```
📋 优化后的任务列表：

| # | 原始输入 | 优化后名称 | 优化说明 |
|---|---------|-----------|---------|
| 1 | 用户头像组件 | UserAvatar 头像组件（含状态指示器） | 从设计稿识别出包含在线/离线状态 |
| 2 | 登录页面 | LoginForm 表单组件 | 拆分：先实现表单组件 |
| 3 | (新增) | LoginPage 登录页面 | 拆分：再组装页面 |

⚠️ 变更说明：
- 任务 "登录页面" 已拆分为表单组件(#2)和页面(#3)
```

优化完成后直接继续，无需等待用户确认。用户如需调整可自行在任务列表中修改。

### 3. 读取配置

读取 `.claude/figma-impl-config.json`，如果不存在则创建默认配置：

```json
{
  "maxRetries": 5,
  "devServerCommand": "",
  "devServerUrl": "",
  "devServerPort": "",
  "screenshotWaitMs": 3000,
  "viewportWidth": 1440,
  "viewportHeight": 900,
  "verifyThreshold": 85,
  "sessionTimeout": 600
}
```

**重要**：`devServerCommand`、`devServerUrl`、`devServerPort` 必须由用户提供。如果配置中为空，询问用户并写入配置文件。

### 4. 创建任务文件

创建 `.claude/figma-tasks.json`：

```json
[
  {
    "id": 1,
    "name": "优化后的功能名称",
    "originalName": "用户原始输入的名称",
    "description": "AI 根据 Figma 设计稿分析后生成的详细描述",
    "targetPath": "src/components/Example/index.tsx",
    "figmaUrl": "完整URL",
    "figmaFileKey": "xxx",
    "figmaNodeId": "1:2",
    "status": "pending",
    "verifyPassed": false,
    "retryCount": 0,
    "lastError": "",
    "files": [],
    "completedAt": ""
  }
]
```

### 5. 创建进度文件

创建 `.claude/figma-progress.md`：

```markdown
# Figma 实现进度

## 项目信息
- 技术栈: (从配置读取)
- 总任务数: N
- 创建时间: YYYY-MM-DD HH:MM

## 执行日志
（每轮执行后追加）
```

### 6. 安装 harness 脚本

将 harness 脚本复制到项目根目录：

```bash
cp "${CLAUDE_PLUGIN_ROOT}/scripts/run-figma-impl.sh" ./run-figma-impl.sh
chmod +x ./run-figma-impl.sh
```

如果 `${CLAUDE_PLUGIN_ROOT}` 不可用，则直接告知用户从插件目录手动复制，或提供脚本内容让用户自行创建。

### 7. 初始化完成

输出任务列表概览，告知用户：
- 运行 `./run-figma-impl.sh` 开始自动执行
- 或使用 `./run-figma-impl.sh --dry-run` 预览执行计划
- 或使用 `./run-figma-impl.sh --status` 查看任务状态

---

