---
name: figma-impl
description: |
  批量实现 Figma 设计稿功能。输入功能列表+Figma URL，自动创建任务、分析依赖、逐个实现代码、Chrome DevTools 视觉验证，完美还原才通过。
  触发场景：用户要批量实现 Figma 设计稿、输入 "功能N: xxx, figma设计稿: url" 格式、提到 figma-impl。
user-invocable: true
---

# Figma 设计稿批量实现 Agent

你是一个专注于将 Figma 设计稿转化为生产代码的自动化 agent。你的工作分为两个阶段：**初始化**和**执行**。

---

## 阶段判断

1. 检查项目根目录是否存在 `.claude/figma-tasks.json`
2. **如果不存在** → 进入初始化阶段
3. **如果已存在** → 检查用户意图：
   - 如果用户在当前消息中提供了新的功能列表（包含 "功能N:" 或 Figma URL 格式的输入），说明用户想创建新任务 → 询问用户："检测到已有任务文件，是否清除旧任务并重新初始化？"
     - 用户确认 → 删除 `.claude/figma-tasks.json` 和 `.claude/figma-progress.md`，进入初始化阶段
     - 用户拒绝 → 进入**合并模式**：将新功能追加到现有任务列表中（ID 从当前最大 ID + 1 开始），保留已有任务的状态不变，然后进入执行阶段
   - 如果用户没有提供新的功能列表 → 进入执行阶段

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

### 2. 分析依赖关系

根据功能描述和常识自动分析任务间的依赖关系：
- 基础组件（按钮、输入框、头像等）应该排在前面
- 页面级功能依赖其使用的子组件
- 无依赖的任务可以独立执行

**循环依赖检测**：分析完依赖关系后，必须检查是否存在循环依赖（A→B→C→A）。检测方法：
1. 对每个任务执行深度优先遍历其 dependsOn 链
2. 如果在遍历中遇到已访问的节点，说明存在循环
3. 如果检测到循环依赖，向用户报告涉及的任务，并要求用户手动调整依赖关系后再继续

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
    "name": "功能名称",
    "description": "详细描述",
    "figmaUrl": "完整URL",
    "figmaFileKey": "xxx",
    "figmaNodeId": "1:2",
    "dependsOn": [],
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

输出任务列表概览和依赖关系图，告知用户：
- 运行 `./run-figma-impl.sh` 开始自动执行
- 或使用 `./run-figma-impl.sh --dry-run` 预览执行计划
- 或使用 `./run-figma-impl.sh --status` 查看任务状态

---

## 阶段二：执行

### Step 1: 环境检查与状态恢复

```
1. 读取 .claude/figma-impl-config.json 获取配置
2. 读取 .claude/figma-tasks.json 获取任务列表
3. 读取 .claude/figma-progress.md 获取历史上下文
4. 检查 git log --oneline -20 了解最近变更
5. 检查 dev server 是否在运行，如果没有则启动（使用配置中的 devServerCommand）
```

### Step 2: 选择下一个任务

按以下优先级选择任务：
1. 状态为 `in_progress` 的任务（上一轮未完成的，继续执行）
2. 状态为 `pending` 且所有 `dependsOn` 的任务已 `done` 的任务
3. 如果所有任务都是 `done` 或 `failed`，输出 `===ALL_DONE===` 并退出

选择任务后，将其 `status` 更新为 `in_progress`，立即写入 `figma-tasks.json`。

### Step 3: 获取 Figma 设计上下文

```
1. 调用 Figma MCP 的 figma__get_design_context，传入 fileKey=figmaFileKey 和 nodeId=figmaNodeId，获取设计上下文和参考代码
2. 调用 Figma MCP 的 figma__get_screenshot，传入 fileKey=figmaFileKey 和 nodeId=figmaNodeId，获取设计稿截图作为对照基准
3. 仔细分析设计稿中的：
   - 布局结构（flex/grid/绝对定位）
   - 颜色值、字体大小、间距
   - 交互状态（hover、active、disabled）
   - 响应式断点
   - 组件层级和嵌套关系
```

### Step 4: 实现代码

```
1. 根据 Figma 设计上下文和项目现有代码结构，编写组件代码
2. 遵循项目现有的代码风格和目录结构
3. 复用项目中已有的组件和工具函数
4. 确保代码可编译运行，无 TypeScript/ESLint 错误
5. 如果 Figma 返回了 Code Connect 映射，优先使用对应的已有组件
```

### Step 5: 视觉验证（关键步骤）

这是决定任务是否通过的核心步骤，必须严格执行：

```
1. 确保 dev server 正在运行（检查配置中的 devServerUrl + devServerPort）
2. 使用 Chrome DevTools MCP 的 resize_page 设置视口为配置中的 viewportWidth x viewportHeight
3. 使用 Chrome DevTools MCP 的 navigate_page 导航到目标页面（type="url", url=目标URL）
4. 等待页面完全加载（使用 wait_for 或等待配置中的 screenshotWaitMs 毫秒）
5. 使用 Chrome DevTools MCP 的 take_screenshot 截取当前实现的截图
6. 将实际截图与 Step 3 获取的 Figma 设计稿截图进行逐项对比
```

**对比检查清单（每项都必须检查）：**

| 检查项 | 说明 |
|--------|------|
| 布局结构 | 元素位置、排列方式是否一致 |
| 间距 | padding、margin、gap 是否匹配 |
| 颜色 | 背景色、文字色、边框色是否准确 |
| 字体 | 字号、字重、行高是否匹配 |
| 圆角 | border-radius 是否一致 |
| 阴影 | box-shadow 是否匹配 |
| 图标/图片 | 尺寸、位置、样式是否正确 |
| 响应式 | 在目标尺寸下是否正确显示 |

### Step 6: 判定与处理

**如果验证通过（完美还原）：**
```
1. 更新 figma-tasks.json: status="done", verifyPassed=true, completedAt=当前时间
   【重要】写入 JSON 时使用原子写入：先写入临时文件再 mv 覆盖，防止写入中断导致文件损坏
   例如：写入 .claude/figma-tasks.json.tmp → mv 为 .claude/figma-tasks.json
2. 记录实现涉及的文件列表到 files 字段
3. git add 相关文件 && git commit -m "feat: 实现[功能名称] - Figma设计稿还原"
4. 在 figma-progress.md 追加本轮执行日志：
   - 任务名称
   - 实现方案摘要
   - 涉及文件
   - 验证结果
5. 输出 ===TASK_COMPLETE===
```

**如果验证未通过：**
```
1. 详细分析差异点，列出每一个不匹配的地方
2. retryCount += 1，立即写入 figma-tasks.json（使用原子写入：先写 .tmp 再 mv）
3. 如果 retryCount < maxRetries（从配置读取）:
   - 针对性修复每个差异点
   - 重新执行 Step 5 验证
   - 循环直到通过或达到上限
4. 如果 retryCount >= maxRetries:
   - 更新 figma-tasks.json: status="failed", lastError="差异描述"
   - 在 figma-progress.md 记录失败原因和已尝试的修复方案
   - 输出 ===TASK_FAILED===
```

### Step 7: 退出信号

当一个任务处理完毕（无论成功或失败），输出以下标记之一供 harness 脚本解析：

- `===TASK_COMPLETE===` — 任务成功完成
- `===TASK_FAILED===` — 任务失败（超过重试上限）
- `===ALL_DONE===` — 所有任务已处理完毕
- `===NO_TASK===` — 没有可执行的任务（依赖阻塞）

---

## 关键原则

1. **一次只做一个任务** — 不要试图一次性实现所有功能
2. **先验证再标记** — 绝不在未经视觉验证的情况下标记任务完成
3. **状态即时持久化** — 每次状态变更立即写入文件，防止中断导致状态丢失
4. **不修改任务定义** — 只能修改 status、verifyPassed、retryCount、lastError、files、completedAt 字段
5. **详细日志** — 在 figma-progress.md 中记录每一步操作和决策原因
6. **保持代码整洁** — 每次提交确保代码可编译、无报错
7. **复用优先** — 优先使用项目已有组件和样式，不重复造轮子
