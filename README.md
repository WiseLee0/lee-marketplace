# Claude Plugins Marketplace

A collection of Claude Code plugins for Figma design-to-code workflows.

## Plugins

| Plugin | Description |
|--------|-------------|
| [figma-impl](plugins/figma-impl/) | 从 Figma 设计稿批量实现 React 组件，自动视觉验证 |

## 安装

```bash
# 添加 marketplace
/plugin marketplace add <owner>/figma-impl-plugin

# 安装插件
/plugin install figma-impl@figma-impl-marketplace
```

## 插件详情

### figma-impl

从 Figma 设计稿批量实现 React 组件，并通过 Chrome DevTools 自动进行视觉验证。

**功能概述：**

1. 你提供一组功能列表和对应的 Figma 设计稿 URL
2. 插件自动创建结构化任务列表，分析任务间的依赖关系
3. Harness 脚本循环调用 Claude Code，每轮会话实现一个功能
4. 每次实现都会通过 Chrome DevTools 截图与 Figma 设计稿进行视觉对比验证
5. 只有完美还原才会通过，否则自动修复并重新验证

**前置条件：**

- 已安装 [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- 已安装 [jq](https://jqlang.github.io/jq/)（`brew install jq`）
- 已安装 Figma 桌面客户端并配置 Figma MCP 服务
- 已配置 Chrome DevTools MCP 服务

详细使用文档见 [plugins/figma-impl/README.md](plugins/figma-impl/README.md)。

## 目录结构

```
├── .claude-plugin/
│   └── marketplace.json     # Marketplace 定义
├── plugins/
│   └── figma-impl/          # figma-impl 插件
│       ├── .claude-plugin/
│       │   └── plugin.json
│       ├── scripts/
│       ├── skills/
│       └── templates/
└── README.md
```

## 添加新插件

1. 在 `plugins/` 下创建新目录
2. 添加 `.claude-plugin/plugin.json` 插件清单
3. 在 `.claude-plugin/marketplace.json` 的 `plugins` 数组中添加条目

## License

MIT
