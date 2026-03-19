#!/bin/bash
#
# figma-impl plugin — Harness 循环执行脚本
#
# 用法:
#   ./run-figma-impl.sh                    # 正常执行
#   ./run-figma-impl.sh --dry-run          # 预览模式
#   ./run-figma-impl.sh --status           # 查看任务状态
#   ./run-figma-impl.sh --reset <id>       # 重置指定任务
#   ./run-figma-impl.sh --reset-all-failed # 重置所有失败任务
#
# Ctrl+C 可随时中断执行，进度自动保存。
#

set -euo pipefail

# ============================================================
# 颜色
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================
# 路径（脚本运行在用户项目根目录）
# ============================================================
# 解析 symlink，确保获取真实路径
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
PROJECT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
CLAUDE_DIR="$PROJECT_DIR/.claude"
TASKS_FILE="$CLAUDE_DIR/figma-tasks.json"
PROGRESS_FILE="$CLAUDE_DIR/figma-progress.md"
CONFIG_FILE="$CLAUDE_DIR/figma-impl-config.json"

# ============================================================
# 中断处理
# ============================================================
INTERRUPTED=false
CLAUDE_PID=""
DEV_SERVER_PID=""
TIMEOUT_PID=""

on_exit() {
    # 终止超时监控进程
    if [ -n "${TIMEOUT_PID:-}" ] && kill -0 "$TIMEOUT_PID" 2>/dev/null; then
        kill "$TIMEOUT_PID" 2>/dev/null || true
    fi
    # 终止正在运行的 claude 进程（发送 TERM 给进程组）
    if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill -- -"$CLAUDE_PID" 2>/dev/null || kill "$CLAUDE_PID" 2>/dev/null || true
        wait "$CLAUDE_PID" 2>/dev/null || true
    fi
    # 确保 dev server 被关闭
    stop_dev_server
    # 用户中断时显示提示信息
    if $INTERRUPTED; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  执行已中断 (Ctrl+C)${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  当前进度已保存。你可以："
        echo -e "    ${CYAN}./run-figma-impl.sh${NC}          继续执行"
        echo -e "    ${CYAN}./run-figma-impl.sh --status${NC}  查看状态"
        echo ""
    fi
}

on_signal() {
    INTERRUPTED=true
    # 立即终止子进程，不等待
    if [ -n "${TIMEOUT_PID:-}" ] && kill -0 "$TIMEOUT_PID" 2>/dev/null; then
        kill "$TIMEOUT_PID" 2>/dev/null || true
    fi
    if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill -- -"$CLAUDE_PID" 2>/dev/null || kill "$CLAUDE_PID" 2>/dev/null || true
    fi
    exit 130
}

trap on_exit EXIT
trap on_signal SIGINT SIGTERM SIGHUP

# ============================================================
# 工具函数
# ============================================================

validate_json() {
    local file="$1"
    if ! jq empty "$file" 2>/dev/null; then
        echo -e "${RED}  [x] JSON 文件损坏: $file${NC}"
        echo -e "      请检查文件内容是否为合法 JSON"
        return 1
    fi
    return 0
}

check_prerequisites() {
    local errors=0

    if ! command -v claude &>/dev/null; then
        echo -e "${RED}  [x] claude CLI 未安装${NC}"
        echo -e "      安装: ${CYAN}npm install -g @anthropic-ai/claude-code${NC}"
        errors=$((errors + 1))
    fi

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}  [x] jq 未安装${NC}"
        echo -e "      安装: ${CYAN}brew install jq${NC} (macOS) / ${CYAN}apt install jq${NC} (Linux)"
        errors=$((errors + 1))
    fi

    if [ ! -f "$TASKS_FILE" ]; then
        echo -e "${RED}  [x] 未找到任务文件 .claude/figma-tasks.json${NC}"
        echo -e "      请先在 Claude Code 中运行 ${CYAN}/figma-impl:figma-impl-plan${NC} 创建任务列表"
        errors=$((errors + 1))
    elif ! validate_json "$TASKS_FILE"; then
        errors=$((errors + 1))
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}  [x] 未找到配置文件 .claude/figma-impl-config.json${NC}"
        echo -e "      请先在 Claude Code 中运行 ${CYAN}/figma-impl:figma-impl-plan${NC} 初始化项目"
        errors=$((errors + 1))
    elif ! validate_json "$CONFIG_FILE"; then
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        echo ""
        exit 1
    fi

    # 检查 Figma 桌面客户端
    if [ "$(uname)" = "Darwin" ]; then
        if [ ! -d "/Applications/Figma.app" ]; then
            echo -e "${YELLOW}  [!] 未检测到 Figma 桌面客户端${NC}"
            echo -e "      Figma MCP 服务需要桌面客户端运行"
            echo -e "      安装: ${CYAN}brew install --cask figma${NC}"
            echo -e "      安装 MCP 插件: ${CYAN}claude plugin marketplace add anthropics/claude-plugins-official${NC}"
            echo -e "                     ${CYAN}claude plugin install figma@claude-plugins-official${NC}"
            echo ""
        elif ! pgrep -x "Figma" &>/dev/null; then
            echo -e "${YELLOW}  [!] Figma 桌面客户端未运行${NC}"
            echo -e "      请先启动 Figma 客户端，MCP 服务需要连接桌面端"
            echo ""
        fi
    fi

    # 检查 Chrome 浏览器
    if [ "$(uname)" = "Darwin" ]; then
        if [ ! -d "/Applications/Google Chrome.app" ]; then
            echo -e "${YELLOW}  [!] 未检测到 Google Chrome${NC}"
            echo -e "      Chrome DevTools MCP 服务需要 Chrome 浏览器"
            echo -e "      安装: ${CYAN}brew install --cask google-chrome${NC}"
            echo ""
        fi
    fi

    # 检查循环依赖
    if [ -f "$TASKS_FILE" ]; then
        local has_cycle
        has_cycle=$(jq '
            def check_cycle($id; $visited; $tasks):
                if ($visited | index($id)) then true
                else
                    ($tasks | map(select(.id == $id))[0].dependsOn // []) as $deps |
                    if ($deps | length) == 0 then false
                    else any($deps[]; check_cycle(.; ($visited + [$id]); $tasks))
                    end
                end;
            any(.[]; .id as $id | check_cycle($id; []; .))
        ' "$TASKS_FILE" 2>/dev/null || echo "false")

        if [ "$has_cycle" = "true" ]; then
            echo -e "${RED}  [x] 检测到循环依赖！${NC}"
            echo -e "      请检查 .claude/figma-tasks.json 中的 dependsOn 字段"
            echo -e "      修复循环依赖后重新运行"
            echo ""
            exit 1
        fi
    fi

    # 检查配置是否完整
    if [ -f "$CONFIG_FILE" ]; then
        local dev_cmd dev_url
        dev_cmd=$(jq -r '.devServerCommand // ""' "$CONFIG_FILE")
        dev_url=$(jq -r '.devServerUrl // ""' "$CONFIG_FILE")
        if [ -z "$dev_cmd" ] || [ -z "$dev_url" ]; then
            echo -e "${YELLOW}  [!] 配置不完整：devServerCommand 或 devServerUrl 为空${NC}"
            echo -e "      请编辑 ${CYAN}.claude/figma-impl-config.json${NC} 填写开发服务器信息"
            echo ""
            exit 1
        fi
    fi
}

# ============================================================
# Dev Server 管理
# ============================================================

start_dev_server() {
    local dev_cmd dev_port
    dev_cmd=$(jq -r '.devServerCommand // ""' "$CONFIG_FILE")
    dev_port=$(jq -r '.devServerPort // ""' "$CONFIG_FILE")

    if [ -z "$dev_cmd" ]; then
        return
    fi

    # 检查端口是否已被占用（dev server 可能已在运行）
    if [ -n "$dev_port" ] && lsof -i :"$dev_port" &>/dev/null; then
        echo -e "  ${DIM}Dev server 已在端口 $dev_port 运行${NC}"
        return
    fi

    echo -e "  ${CYAN}启动 dev server: $dev_cmd${NC}"
    # 后台启动 dev server
    $dev_cmd &>/dev/null &
    DEV_SERVER_PID=$!

    # 等待 dev server 启动
    if [ -n "$dev_port" ]; then
        local wait_count=0
        while ! lsof -i :"$dev_port" &>/dev/null; do
            # 检查进程是否已退出（命令本身失败）
            if ! kill -0 "$DEV_SERVER_PID" 2>/dev/null; then
                echo ""
                echo -e "${RED}  [x] Dev server 启动失败${NC}"
                echo ""
                echo -e "  可能的原因："
                echo -e "    1. 命令不正确: ${CYAN}$dev_cmd${NC}"
                echo -e "    2. 依赖未安装，请先运行 ${CYAN}npm install${NC} 或 ${CYAN}pnpm install${NC}"
                echo -e "    3. 端口 $dev_port 被其他进程占用"
                echo -e "       检查: ${CYAN}lsof -i :$dev_port${NC}"
                echo -e "       释放: ${CYAN}kill \$(lsof -ti :$dev_port)${NC}"
                echo ""
                DEV_SERVER_PID=""
                exit 1
            fi
            wait_count=$((wait_count + 1))
            if [ "$wait_count" -ge 30 ]; then
                echo ""
                echo -e "${RED}  [x] Dev server 启动超时（30s）${NC}"
                echo ""
                echo -e "  可能的原因："
                echo -e "    1. 项目编译时间过长，可尝试增大超时时间"
                echo -e "    2. 端口 $dev_port 与实际启动端口不一致"
                echo -e "       请检查 ${CYAN}.claude/figma-impl-config.json${NC} 中的 devServerPort 配置"
                echo -e "    3. dev server 启动后卡住，请手动运行 ${CYAN}$dev_cmd${NC} 排查"
                echo ""
                # 清理已启动的进程
                kill "$DEV_SERVER_PID" 2>/dev/null || true
                DEV_SERVER_PID=""
                exit 1
            fi
            sleep 1
        done
        echo -e "  ${GREEN}Dev server 已启动 (端口 $dev_port)${NC}"
    else
        sleep 3
        if ! kill -0 "$DEV_SERVER_PID" 2>/dev/null; then
            echo ""
            echo -e "${RED}  [x] Dev server 启动失败${NC}"
            echo ""
            echo -e "  可能的原因："
            echo -e "    1. 命令不正确: ${CYAN}$dev_cmd${NC}"
            echo -e "    2. 依赖未安装，请先运行 ${CYAN}npm install${NC} 或 ${CYAN}pnpm install${NC}"
            echo -e "  建议在 ${CYAN}.claude/figma-impl-config.json${NC} 中配置 devServerPort 以获得更精确的启动检测"
            echo ""
            DEV_SERVER_PID=""
            exit 1
        fi
        echo -e "  ${GREEN}Dev server 已启动${NC}"
    fi
}

stop_dev_server() {
    if [ -n "$DEV_SERVER_PID" ] && kill -0 "$DEV_SERVER_PID" 2>/dev/null; then
        echo -e "  ${DIM}关闭 dev server (PID: $DEV_SERVER_PID)${NC}"
        kill "$DEV_SERVER_PID" 2>/dev/null || true
        wait "$DEV_SERVER_PID" 2>/dev/null || true
    fi
    DEV_SERVER_PID=""
    # 按端口清理残留进程（npm/pnpm 会 spawn 子进程）
    local dev_port
    dev_port=$(jq -r '.devServerPort // ""' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$dev_port" ]; then
        local remaining_pids
        remaining_pids=$(lsof -ti :"$dev_port" 2>/dev/null || true)
        if [ -n "$remaining_pids" ]; then
            echo -e "  ${DIM}清理端口 $dev_port 上的残留进程${NC}"
            echo "$remaining_pids" | xargs kill 2>/dev/null || true
        fi
    fi
}

get_task_counts() {
    local total pending in_progress done failed
    total=$(jq 'length' "$TASKS_FILE")
    pending=$(jq '[.[] | select(.status == "pending")] | length' "$TASKS_FILE")
    in_progress=$(jq '[.[] | select(.status == "in_progress")] | length' "$TASKS_FILE")
    done=$(jq '[.[] | select(.status == "done")] | length' "$TASKS_FILE")
    failed=$(jq '[.[] | select(.status == "failed")] | length' "$TASKS_FILE")
    echo "$total $pending $in_progress $done $failed"
}

print_status() {
    local counts
    counts=($(get_task_counts))
    local total=${counts[0]} pending=${counts[1]} in_progress=${counts[2]} done=${counts[3]} failed=${counts[4]}

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Figma Impl — 任务状态${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  总计: ${BOLD}$total${NC}  |  待执行: ${BLUE}$pending${NC}  |  进行中: ${YELLOW}$in_progress${NC}  |  完成: ${GREEN}$done${NC}  |  失败: ${RED}$failed${NC}"
    echo ""

    jq -r '.[] | "  [\(.id)] \(.status | if . == "done" then "\u2705" elif . == "failed" then "\u274c" elif . == "in_progress" then "\ud83d\udd04" else "\u23f3" end) \(.name)\(if .retryCount > 0 then " (retry \(.retryCount))" else "" end)\(if .lastError != "" then " — \(.lastError)" else "" end)"' "$TASKS_FILE"
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

has_remaining_tasks() {
    local remaining
    remaining=$(jq '[.[] | select(.status == "pending" or .status == "in_progress")] | length' "$TASKS_FILE")
    [ "$remaining" -gt 0 ]
}

get_next_task_name() {
    local task_name

    # 优先: in_progress
    task_name=$(jq -r '[.[] | select(.status == "in_progress")][0].name // empty' "$TASKS_FILE")
    if [ -n "$task_name" ]; then
        echo "$task_name"
        return
    fi

    # 其次: 依赖已满足的 pending
    local done_ids
    done_ids=$(jq '[.[] | select(.status == "done") | .id]' "$TASKS_FILE")

    task_name=$(jq -r --argjson done "$done_ids" '
        [.[] | select(.status == "pending") | select(
            (.dependsOn | length == 0) or
            (.dependsOn | all(. as $dep | $done | any(. == $dep)))
        )][0].name // empty
    ' "$TASKS_FILE")

    echo "$task_name"
}

reset_all_tasks() {
    jq 'map(.status = "pending" | .verifyPassed = false | .retryCount = 0 | .lastError = "" | .files = [] | .completedAt = "")' \
        "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"

    local task_count
    task_count=$(jq 'length' "$TASKS_FILE")
    cat > "$PROGRESS_FILE" <<EOF
# Figma 实现进度

## 项目信息
- 总任务数: $task_count
- 重置时间: $(date '+%Y-%m-%d %H:%M:%S')

## 执行日志
EOF
}

reset_failed_tasks() {
    jq 'map(if .status == "failed" then .status = "pending" | .verifyPassed = false | .retryCount = 0 | .lastError = "" else . end)' \
        "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
}

# ============================================================
# 启动前状态检查 — 交互式菜单
# ============================================================

prompt_history_action() {
    local counts
    counts=($(get_task_counts))
    local total=${counts[0]} pending=${counts[1]} in_progress=${counts[2]} done=${counts[3]} failed=${counts[4]}

    # 全部 pending，首次运行，直接开始
    if [ "$done" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$in_progress" -eq 0 ]; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}  检测到历史执行记录${NC}"
    echo ""
    echo -e "  完成: ${GREEN}$done${NC}  |  失败: ${RED}$failed${NC}  |  进行中: ${YELLOW}$in_progress${NC}  |  待执行: ${BLUE}$pending${NC}"
    echo ""

    if [ "$pending" -gt 0 ] || [ "$in_progress" -gt 0 ]; then
        # 还有未完成任务
        echo -e "  ${BOLD}1)${NC} 继续执行 — 从上次中断处继续 ${DIM}(剩余 $((pending + in_progress)) 个)${NC}"
        echo -e "  ${BOLD}2)${NC} 全部重置 — 清空所有记录，从头开始"
        [ "$failed" -gt 0 ] && echo -e "  ${BOLD}3)${NC} 仅重试失败 — 重置 $failed 个失败任务"
        echo -e "  ${BOLD}q)${NC} 退出"
        echo ""
        while true; do
            echo -ne "  请选择 [1/2$([ "$failed" -gt 0 ] && echo '/3')/q]: "
            read -r choice
            case "$choice" in
                1) echo -e "  ${CYAN}-> 继续执行${NC}"; return 0 ;;
                2) reset_all_tasks; echo -e "  ${CYAN}-> 已重置全部任务${NC}"; return 0 ;;
                3) [ "$failed" -gt 0 ] && { reset_failed_tasks; echo -e "  ${CYAN}-> 已重置 $failed 个失败任务${NC}"; return 0; }; echo -e "  ${RED}无效选择${NC}" ;;
                q|Q) exit 0 ;;
                *) echo -e "  ${RED}无效选择${NC}" ;;
            esac
        done
    else
        # 全部处理完毕
        echo -e "  所有任务都已处理完毕。"
        echo ""
        echo -e "  ${BOLD}1)${NC} 全部重置 — 重新执行全部任务"
        [ "$failed" -gt 0 ] && echo -e "  ${BOLD}2)${NC} 仅重试失败 — 重置 $failed 个失败任务"
        echo -e "  ${BOLD}q)${NC} 退出"
        echo ""
        while true; do
            echo -ne "  请选择 [1$([ "$failed" -gt 0 ] && echo '/2')/q]: "
            read -r choice
            case "$choice" in
                1) reset_all_tasks; echo -e "  ${CYAN}-> 已重置全部任务${NC}"; return 0 ;;
                2) [ "$failed" -gt 0 ] && { reset_failed_tasks; echo -e "  ${CYAN}-> 已重置 $failed 个失败任务${NC}"; return 0; }; echo -e "  ${RED}无效选择${NC}" ;;
                q|Q) exit 0 ;;
                *) echo -e "  ${RED}无效选择${NC}" ;;
            esac
        done
    fi
}

# ============================================================
# 子命令处理
# ============================================================

case "${1:-}" in
    --status)
        check_prerequisites
        print_status
        exit 0
        ;;
    --dry-run)
        check_prerequisites
        echo -e "${CYAN}  预览模式 — 任务将按依赖顺序执行：${NC}"
        echo ""
        print_status
        exit 0
        ;;
    --reset)
        check_prerequisites
        [ -z "${2:-}" ] && { echo -e "${RED}用法: ./run-figma-impl.sh --reset <task_id>${NC}"; exit 1; }
        if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}  错误: task_id 必须是数字，收到: '${2}'${NC}"
            exit 1
        fi
        # 检查任务是否存在
        if ! jq -e --argjson id "$2" '[.[] | select(.id == $id)] | length > 0' "$TASKS_FILE" &>/dev/null; then
            echo -e "${RED}  错误: 未找到 ID 为 $2 的任务${NC}"
            exit 1
        fi
        jq --argjson id "$2" \
            'map(if .id == $id then .status = "pending" | .verifyPassed = false | .retryCount = 0 | .lastError = "" else . end)' \
            "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
        echo -e "${GREEN}  任务 #$2 已重置${NC}"
        exit 0
        ;;
    --reset-all-failed)
        check_prerequisites
        reset_failed_tasks
        echo -e "${GREEN}  所有失败任务已重置${NC}"
        exit 0
        ;;
    --help|-h)
        cat <<'HELP'
figma-impl harness — 循环执行 Figma 设计稿实现任务

用法:
  ./run-figma-impl.sh                    正常执行
  ./run-figma-impl.sh --status           查看任务状态
  ./run-figma-impl.sh --dry-run          预览执行计划
  ./run-figma-impl.sh --reset <id>       重置指定任务
  ./run-figma-impl.sh --reset-all-failed 重置所有失败任务
  ./run-figma-impl.sh --help             显示帮助

Ctrl+C 可随时中断，进度自动保存。
HELP
        exit 0
        ;;
esac

# ============================================================
# 主循环
# ============================================================

check_prerequisites

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Figma Impl — 批量设计稿实现${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

prompt_history_action

echo ""
echo -e "  按 ${YELLOW}Ctrl+C${NC} 随时中断，进度自动保存"
echo ""

print_status

# 启动 dev server
start_dev_server

# 读取超时配置（默认 10 分钟）
SESSION_TIMEOUT=$(jq -r '.sessionTimeout // 600' "$CONFIG_FILE")

ROUND=0

while has_remaining_tasks; do
    $INTERRUPTED && break

    # 每轮开始前校验 JSON 完整性
    if ! validate_json "$TASKS_FILE"; then
        echo -e "${RED}  任务文件损坏，中止执行。请检查 .claude/figma-tasks.json${NC}"
        break
    fi

    ROUND=$((ROUND + 1))
    NEXT_TASK=$(get_next_task_name)

    # 计算进度
    local_counts=($(get_task_counts))
    TOTAL=${local_counts[0]}
    DONE_COUNT=${local_counts[3]}

    if [ -z "$NEXT_TASK" ]; then
        echo -e "${YELLOW}  所有待执行任务的依赖尚未满足，无法继续。${NC}"
        echo -e "  请检查是否有 failed 的依赖任务需要处理。"
        print_status
        break
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Round $ROUND | $NEXT_TASK  ${DIM}($DONE_COUNT/$TOTAL done)${NC}"
    echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 读取配置值用于 prompt
    VIEWPORT_W=$(jq -r '.viewportWidth // 1440' "$CONFIG_FILE")
    VIEWPORT_H=$(jq -r '.viewportHeight // 900' "$CONFIG_FILE")
    MAX_RETRIES=$(jq -r '.maxRetries // 5' "$CONFIG_FILE")
    SCREENSHOT_WAIT=$(jq -r '.screenshotWaitMs // 3000' "$CONFIG_FILE")
    DEV_URL=$(jq -r '.devServerUrl // ""' "$CONFIG_FILE")

    # 构建 prompt — 完整内联执行规范（因为 harness 模式下 Claude 无法访问插件 SKILL.md）
    PROMPT="你现在处于 figma-impl 的 harness 执行阶段，负责实现一个 Figma 设计稿功能。

当前任务: ${NEXT_TASK}
Dev Server URL: ${DEV_URL}

## 执行步骤

### Step 1: 环境检查与状态恢复
1. 读取 .claude/figma-impl-config.json 获取配置
2. 读取 .claude/figma-tasks.json 获取任务列表
3. 读取 .claude/figma-progress.md 获取历史上下文
4. git log --oneline -20 了解最近变更

### Step 2: 选择任务
找到名为「${NEXT_TASK}」的任务，将其 status 更新为 in_progress，立即写入 figma-tasks.json。
【原子写入】写 JSON 时先写入 .tmp 文件再 mv 覆盖，防止中断导致损坏。

### Step 3: 获取 Figma 设计上下文
1. 调用 Figma MCP 的 figma__get_design_context，传入 fileKey 和 nodeId，获取设计上下文和参考代码
2. 调用 Figma MCP 的 figma__get_screenshot，传入 fileKey 和 nodeId，获取设计稿截图作为对照基准
3. 仔细分析设计稿中的布局结构、颜色值、字体、间距、交互状态、组件层级

### Step 4: 实现代码
1. 根据 Figma 设计上下文和项目现有代码结构编写组件代码
2. 遵循项目现有的代码风格和目录结构
3. 复用项目已有的组件和工具函数
4. 确保代码可编译运行，无 TypeScript/ESLint 错误
5. 如果 Figma 返回了 Code Connect 映射，优先使用对应的已有组件

### Step 5: 视觉验证（关键步骤）
1. Dev server 已由 harness 脚本启动，无需你再启动
2. 使用 Chrome DevTools MCP 的 resize_page 设置视口为 ${VIEWPORT_W} x ${VIEWPORT_H}
3. 使用 Chrome DevTools MCP 的 navigate_page 导航到目标页面（type=\"url\", url=目标URL）
4. 等待页面完全加载（等待 ${SCREENSHOT_WAIT} 毫秒，可用 wait_for 等待关键文本出现）
5. 使用 Chrome DevTools MCP 的 take_screenshot 截取当前实现的截图
6. 将实际截图与 Step 3 获取的 Figma 设计稿截图逐项对比

对比检查清单：布局结构、间距(padding/margin/gap)、颜色(背景/文字/边框)、字体(字号/字重/行高)、圆角、阴影、图标/图片、响应式表现

### Step 6: 判定与处理
**验证通过：**
1. 更新 figma-tasks.json: status=\"done\", verifyPassed=true, completedAt=当前时间（原子写入）
2. 记录实现涉及的文件列表到 files 字段
3. git add 相关文件 && git commit -m \"feat: 实现[功能名称] - Figma设计稿还原\"
4. 在 figma-progress.md 追加本轮执行日志
5. 输出 ===TASK_COMPLETE===

**验证未通过：**
1. 详细分析差异点
2. retryCount += 1，立即原子写入 figma-tasks.json
3. 如果 retryCount < ${MAX_RETRIES}: 针对性修复 → 重新验证 → 循环
4. 如果 retryCount >= ${MAX_RETRIES}: status=\"failed\", lastError=\"差异描述\", 输出 ===TASK_FAILED===

## 退出信号（必须输出其中之一）
- ===TASK_COMPLETE=== 任务成功
- ===TASK_FAILED=== 任务失败
- ===ALL_DONE=== 所有任务完毕
- ===NO_TASK=== 无可执行任务"

    OUTPUT_FILE=$(mktemp)
    SECONDS=0

    claude --dangerously-skip-permissions \
        -p "$PROMPT" \
        2>&1 | tee "$OUTPUT_FILE" &
    CLAUDE_PID=$!

    # macOS 没有 timeout 命令，用后台监控实现超时
    (
      sleep "$SESSION_TIMEOUT" 2>/dev/null
      if kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null
      fi
    ) &
    TIMEOUT_PID=$!

    wait "$CLAUDE_PID" 2>/dev/null
    EXIT_CODE=$?
    CLAUDE_PID=""
    if [ -n "$TIMEOUT_PID" ] && kill -0 "$TIMEOUT_PID" 2>/dev/null; then
        kill "$TIMEOUT_PID" 2>/dev/null || true
        wait "$TIMEOUT_PID" 2>/dev/null || true
    fi
    TIMEOUT_PID=""
    ELAPSED=$SECONDS

    $INTERRUPTED && { rm -f "$OUTPUT_FILE"; break; }

    # 格式化耗时
    if [ "$ELAPSED" -ge 60 ]; then
        ELAPSED_STR="$((ELAPSED / 60))m$((ELAPSED % 60))s"
    else
        ELAPSED_STR="${ELAPSED}s"
    fi

    # 超时检测
    if [ "$EXIT_CODE" -eq 124 ]; then
        echo -e "${RED}  -> 超时: $NEXT_TASK (${SESSION_TIMEOUT}s 上限)  耗时: ${ELAPSED_STR}${NC}"
        # 将 in_progress 任务标记为 failed
        jq 'map(if .status == "in_progress" then .status = "failed" | .lastError = "会话超时" else . end)' \
            "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
        rm -f "$OUTPUT_FILE"
        if has_remaining_tasks && ! $INTERRUPTED; then
            echo -e "${DIM}  3s 后开始下一轮...${NC}"
            sleep 3
        fi
        continue
    fi

    # 解析结果
    if grep -q "===ALL_DONE===" "$OUTPUT_FILE"; then
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  所有任务已完成！${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        rm -f "$OUTPUT_FILE"
        print_status
        break
    elif grep -q "===TASK_COMPLETE===" "$OUTPUT_FILE"; then
        echo -e "${GREEN}  -> 完成: $NEXT_TASK  耗时: ${ELAPSED_STR}${NC}"
    elif grep -q "===TASK_FAILED===" "$OUTPUT_FILE"; then
        echo -e "${RED}  -> 失败: $NEXT_TASK (达到重试上限)  耗时: ${ELAPSED_STR}${NC}"
    elif grep -q "===NO_TASK===" "$OUTPUT_FILE"; then
        echo -e "${YELLOW}  -> 无可执行任务（依赖阻塞）${NC}"
        rm -f "$OUTPUT_FILE"
        break
    else
        echo -e "${YELLOW}  -> 未检测到状态标记，可能执行异常  耗时: ${ELAPSED_STR}${NC}"
    fi

    rm -f "$OUTPUT_FILE"

    # 短暂暂停
    if has_remaining_tasks && ! $INTERRUPTED; then
        echo -e "${DIM}  3s 后开始下一轮...${NC}"
        sleep 3
    fi
done

if ! $INTERRUPTED; then
    echo ""
    print_status
    echo -e "${BOLD}  执行结束。${NC}"
    echo ""
fi
