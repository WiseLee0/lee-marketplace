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
IMPL_RESULT_FILE="$CLAUDE_DIR/impl-result.json"
VERIFY_RESULT_FILE="$CLAUDE_DIR/verify-result.json"
FIX_RESULT_FILE="$CLAUDE_DIR/fix-result.json"
REVIEW_RESULT_FILE="$CLAUDE_DIR/review-result.json"
DEV_SERVER_LOG="$CLAUDE_DIR/dev-server.log"

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
    # 终止正在运行的 claude 进程
    if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null || true
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
    # 立即终止所有子进程
    if [ -n "${TIMEOUT_PID:-}" ] && kill -0 "$TIMEOUT_PID" 2>/dev/null; then
        kill "$TIMEOUT_PID" 2>/dev/null || true
    fi
    if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null || true
        # 等一小会儿，不行就 SIGKILL
        sleep 0.5 2>/dev/null || true
        kill -0 "$CLAUDE_PID" 2>/dev/null && kill -9 "$CLAUDE_PID" 2>/dev/null || true
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
        echo -e "      请先在 Claude Code 中运行 ${CYAN}/figma-impl-plan${NC} 创建任务列表"
        errors=$((errors + 1))
    elif ! validate_json "$TASKS_FILE"; then
        errors=$((errors + 1))
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}  [x] 未找到配置文件 .claude/figma-impl-config.json${NC}"
        echo -e "      请先在 Claude Code 中运行 ${CYAN}/figma-impl-plan${NC} 初始化项目"
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
    # 后台启动 dev server（输出到日志文件，避免 /dev/null 导致某些框架阻塞）
    $dev_cmd > "$DEV_SERVER_LOG" 2>&1 &
    DEV_SERVER_PID=$!

    # 等待 dev server 启动
    local start_timeout
    start_timeout=$(jq -r '.devServerStartTimeout // 120' "$CONFIG_FILE")
    if [ -n "$dev_port" ]; then
        local wait_count=0
        while ! lsof -i :"$dev_port" &>/dev/null; do
            # 检查进程是否已退出（命令本身失败）
            if ! kill -0 "$DEV_SERVER_PID" 2>/dev/null; then
                echo ""
                echo -e "${RED}  [x] Dev server 启动失败${NC}"
                echo ""
                echo -e "  日志: ${CYAN}$DEV_SERVER_LOG${NC}"
                tail -5 "$DEV_SERVER_LOG" 2>/dev/null | sed 's/^/  > /'
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
            if [ "$wait_count" -ge "$start_timeout" ]; then
                echo ""
                echo -e "${RED}  [x] Dev server 启动超时（${start_timeout}s）${NC}"
                echo ""
                echo -e "  日志: ${CYAN}$DEV_SERVER_LOG${NC}"
                tail -5 "$DEV_SERVER_LOG" 2>/dev/null | sed 's/^/  > /'
                echo ""
                echo -e "  可能的原因："
                echo -e "    1. 项目编译时间过长，可尝试增大超时时间"
                echo -e "    2. 端口 $dev_port 与实际启动端口不一致"
                echo -e "       请检查 ${CYAN}.claude/figma-impl-config.json${NC} 中的 devServerPort 配置"
                echo -e "    3. dev server 启动后卡住，请手动运行 ${CYAN}$dev_cmd${NC} 排查"
                echo -e "    4. 可在 .claude/figma-impl-config.json 中设置 ${CYAN}devServerStartTimeout${NC} 增大超时（默认 120s）"
                echo ""
                # 清理已启动的进程
                kill "$DEV_SERVER_PID" 2>/dev/null || true
                DEV_SERVER_PID=""
                exit 1
            fi
            # 每 10 秒打印一次等待进度
            if [ $((wait_count % 10)) -eq 0 ] && [ "$wait_count" -gt 0 ]; then
                echo -e "  ${DIM}等待 dev server 启动... (${wait_count}/${start_timeout}s)${NC}"
            fi
            sleep 1
        done
        echo -e "  ${GREEN}Dev server 已启动 (端口 $dev_port, 耗时 ${wait_count}s)${NC}"
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

get_task_figma_url() {
    local task_name="$1"
    jq -r --arg name "$task_name" '[.[] | select(.name == $name)][0].figmaUrl // ""' "$TASKS_FILE"
}

has_figma_design() {
    local task_name="$1"
    local url
    url=$(get_task_figma_url "$task_name")
    [ -n "$url" ] && [ "$url" != "null" ] && [ "$url" != "" ]
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

# 运行一次 Claude 会话
# 用法: run_claude_session "prompt"
# 结果通过全局变量返回: RCS_ELAPSED, RCS_EXIT_CODE
run_claude_session() {
    local prompt="$1"
    SECONDS=0

    claude --dangerously-skip-permissions \
        -p "$prompt" \
        2>&1 &
    CLAUDE_PID=$!

    (
      sleep "$SESSION_TIMEOUT" 2>/dev/null
      if kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null
      fi
    ) &
    TIMEOUT_PID=$!

    wait "$CLAUDE_PID" 2>/dev/null || true
    local _exit_code=$?
    CLAUDE_PID=""
    if [ -n "$TIMEOUT_PID" ] && kill -0 "$TIMEOUT_PID" 2>/dev/null; then
        kill "$TIMEOUT_PID" 2>/dev/null || true
        wait "$TIMEOUT_PID" 2>/dev/null || true
    fi
    TIMEOUT_PID=""

    RCS_ELAPSED=$SECONDS
    RCS_EXIT_CODE=$_exit_code
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

    # 每轮开始前清理上一轮的结果文件
    rm -f "$IMPL_RESULT_FILE" "$VERIFY_RESULT_FILE" "$FIX_RESULT_FILE" "$REVIEW_RESULT_FILE"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Round $ROUND | $NEXT_TASK  ${DIM}($DONE_COUNT/$TOTAL done)${NC}"
    echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 读取配置值用于 prompt
    MAX_RETRIES=$(jq -r '.maxRetries // 5' "$CONFIG_FILE")
    SCREENSHOT_WAIT=$(jq -r '.screenshotWaitMs // 3000' "$CONFIG_FILE")
    DEV_URL=$(jq -r '.devServerUrl // ""' "$CONFIG_FILE")
    VERIFY_THRESHOLD=$(jq -r '.verifyThreshold // 80' "$CONFIG_FILE")
    REVIEW_THRESHOLD=$(jq -r '.reviewThreshold // 80' "$CONFIG_FILE")

    # 判断任务类型
    IS_DESIGN_TASK=true
    if ! has_figma_design "$NEXT_TASK"; then
        IS_DESIGN_TASK=false
    fi

    # 获取任务描述（纯逻辑任务需要用到）
    TASK_DESCRIPTION=$(jq -r --arg name "$NEXT_TASK" '[.[] | select(.name == $name)][0].description // ""' "$TASKS_FILE")

    # ── 共用的环境检查步骤 ──────────────────────────────────
    COMMON_INIT_STEPS="### Step 1: 环境检查与状态恢复
1. 读取 .claude/figma-impl-config.json 获取配置
2. 读取 .claude/figma-tasks.json 获取任务列表
3. 读取 .claude/figma-progress.md 获取历史上下文
4. 读取项目根目录的 CLAUDE.md（如果存在），了解项目规范、技术栈约定和编码风格要求
5. 读取 .claude/rules/figma-design-system.md 和 .claude/figma-design-rules.md（如果存在），了解设计系统规则
6. git log --oneline -20 了解最近变更

### Step 2: 选择任务
找到名为「${NEXT_TASK}」的任务，将其 status 更新为 in_progress，立即写入 figma-tasks.json。
【原子写入】写 JSON 时先写入 .tmp 文件再 mv 覆盖，防止中断导致损坏。"

    if $IS_DESIGN_TASK; then
        # ── Prompt A: Figma 设计稿实现 ──────────────────────────
        IMPL_PROMPT="你现在处于 figma-impl 的 harness 执行阶段，负责实现一个 Figma 设计稿功能。
你只需要完成代码实现，不需要做视觉验证（验证由独立会话完成）。

当前任务: ${NEXT_TASK}
Dev Server URL: ${DEV_URL}

## 执行步骤

${COMMON_INIT_STEPS}

### Step 3: 获取 Figma 设计上下文
1. 调用 Figma MCP 的 figma__get_design_context，传入 fileKey 和 nodeId，获取设计上下文和参考代码
2. 调用 Figma MCP 的 figma__get_screenshot，传入 fileKey 和 nodeId，获取设计稿截图作为对照基准
3. 仔细分析设计稿中的布局结构、颜色值、字体、间距、交互状态、组件层级
4. 查找并读取 Figma 官方 implement-design skill：用 Glob 搜索 ~/.claude/plugins/cache/**/figma/*/skills/implement-design/SKILL.md，如果找到则读取，作为设计稿实现的最佳实践参考

### Step 4: 实现代码
1. 根据 Figma 设计上下文和项目现有代码结构编写组件代码
2. 遵循项目现有的代码风格和目录结构
3. 复用项目已有的组件和工具函数
4. 确保代码可编译运行，无 TypeScript/ESLint 错误
5. 如果 Figma 返回了 Code Connect 映射，优先使用对应的已有组件

### Step 5: 写入结果
确认代码已编写完成、可编译后，将结果写入 .claude/impl-result.json：
- 实现完成：写入 {\"status\": \"done\"}
- 无可执行任务：写入 {\"status\": \"no_task\"}

## 注意事项
- 不修改任务定义：只能修改 status 字段（设为 in_progress），不要改 name、figmaUrl 等定义字段
- 不要做视觉验证、不要截图对比、不要修改 verifyPassed 或 retryCount
- 不要 git commit（由 harness 在验证通过后统一处理）
- 必须将结果写入 .claude/impl-result.json，harness 通过该文件判断会话结果"

        # ── Prompt B: 视觉验证 ──────────────────────────────────
        VERIFY_PROMPT="你是一个严格的视觉 QA 审查员。你的工作是对比 Figma 设计稿和实际实现的截图，找出所有差异。
你不是实现者，你没有写这些代码，你对它没有感情。你的目标是找出问题，而不是找理由通过。

⚠️ 审查原则：
- 宁可误判为不通过，也不要放过差异
- 不要为实现者找借口（如「细微差异可以接受」「整体还原度不错」）
- 每个维度独立评分，不因其他维度表现好而放宽某个维度的标准
- 如果某个元素在设计稿中存在但实现中缺失，该维度直接 0 分

📐 响应式布局容忍规则：
设计稿和实现的视口宽度可能不同，对于使用流式/响应式布局的区域（如 flex: 1、百分比宽度、grid auto-fill 等），应遵循以下原则：
- 元素的绝对宽度差异不应扣分，只要布局结构（列数、排列方向、嵌套关系）一致
- 间距评分只关注固定间距值（gap、padding、margin）是否正确，不因容器/元素宽度变化而扣分
- 图片/卡片等流式元素的宽高比应保持一致，但绝对尺寸差异不扣分
- 文字换行位置可能因容器宽度不同而不同，不应视为差异
- 仍然严格检查：颜色、字号、字重、圆角、阴影、元素是否缺失等与视口无关的属性

当前任务: ${NEXT_TASK}
Dev Server URL: ${DEV_URL}
通过阈值: 每项 ≥ 7 分且总分 ≥ ${VERIFY_THRESHOLD}%

## 执行步骤

### Step 1: 获取 Figma 设计基准
1. 读取 .claude/figma-tasks.json 获取当前任务信息（figmaUrl 中的 fileKey 和 nodeId）
2. 调用 Figma MCP 的 figma__get_screenshot，传入 fileKey 和 nodeId，获取设计稿截图

### Step 2: 截取实现截图
1. Dev server 已由 harness 脚本启动，无需你再启动
2. 使用 Chrome DevTools MCP 的 navigate_page 导航到目标页面（type=\"url\", url=目标URL）
3. 等待页面完全加载（等待 ${SCREENSHOT_WAIT} 毫秒，可用 wait_for 等待关键文本出现）
4. 使用 Chrome DevTools MCP 的 take_screenshot 截取当前实现的截图

### Step 3: 逐项对比评分
对以下每个维度独立打分（0-10 分），并列出具体差异。每个维度有不同权重，影响总分计算：

| 维度 | 权重 | 评分标准 |
|------|------|---------|
| layout | 2.0 | 整体布局结构是否一致（flex/grid方向、嵌套层级、元素排列顺序） |
| spacing | 1.5 | padding/margin/gap 是否匹配（允许 ±2px 误差） |
| colors | 1.5 | 背景色、文字色、边框色、渐变是否匹配 |
| typography | 1.0 | 字号、字重、行高、字体是否匹配 |
| borders | 0.5 | 圆角、边框宽度、边框样式是否匹配 |
| shadows | 0.5 | 阴影是否匹配（包括无阴影 vs 有阴影） |
| icons_images | 1.0 | 图标/图片是否存在、尺寸是否正确、位置是否正确 |
| completeness | 2.0 | 设计稿中所有元素是否都已实现（无遗漏） |

### Step 4: 写入结果
将验证结果写入 .claude/verify-result.json（harness 通过该文件读取评分），格式如下：

{
  \"passed\": false,
  \"scores\": {
    \"layout\": 8,
    \"spacing\": 6,
    \"colors\": 9,
    \"typography\": 7,
    \"borders\": 8,
    \"shadows\": 10,
    \"icons_images\": 5,
    \"completeness\": 7
  },
  \"total_score\": 75,
  \"failed_dimensions\": [\"spacing\", \"icons_images\"],
  \"differences\": [
    \"间距: 卡片之间的 gap 设计稿为 16px，实现为 24px\",
    \"图标: 右上角的关闭按钮图标缺失\",
    \"颜色: 标题文字色设计稿为 #1A1A1A，实现为 #333333\"
  ]
}

评分规则：
- 各维度权重: layout=2.0, spacing=1.5, colors=1.5, typography=1.0, borders=0.5, shadows=0.5, icons_images=1.0, completeness=2.0（权重总和=10.0）
- total_score = Σ(维度分数 × 维度权重) / (权重总和 × 10) × 100，四舍五入取整
  示例: layout=8(×2.0=16) + spacing=6(×1.5=9) + colors=9(×1.5=13.5) + typography=7(×1.0=7) + borders=8(×0.5=4) + shadows=10(×0.5=5) + icons_images=5(×1.0=5) + completeness=7(×2.0=14) = 73.5 → total_score = 74
- passed = true 当且仅当：total_score >= ${VERIFY_THRESHOLD} 且所有维度 >= 7
- failed_dimensions: 列出所有 < 7 分的维度
- differences: 列出所有具体差异，格式为「维度: 具体描述」
- 必须将结果写入 .claude/verify-result.json，这是唯一的结果传递方式"

    else
        # ── Prompt A': 纯逻辑实现 ──────────────────────────────
        IMPL_PROMPT="你现在处于 figma-impl 的 harness 执行阶段，负责实现一个纯逻辑功能（无 Figma 设计稿）。
你只需要完成代码实现，不需要做视觉验证（代码审查由独立会话完成）。

当前任务: ${NEXT_TASK}
任务描述: ${TASK_DESCRIPTION}
Dev Server URL: ${DEV_URL}

## 执行步骤

${COMMON_INIT_STEPS}

### Step 3: 分析需求
1. 仔细阅读任务描述，理解需要实现的功能逻辑
2. 阅读相关的已有代码，理解上下文和依赖关系
3. 如果任务有 dependsOn，查看已完成的依赖任务产出的文件，确保与之衔接

### Step 4: 实现代码
1. 根据任务描述和项目现有代码结构编写功能代码
2. 遵循项目现有的代码风格和目录结构
3. 复用项目已有的组件、工具函数和类型定义
4. 确保代码可编译运行，无 TypeScript/ESLint 错误
5. 处理好边界条件和错误情况
6. 如果涉及 API 调用，确保请求/响应类型正确
7. 如果涉及状态管理，确保状态更新逻辑正确

### Step 5: 写入结果
确认代码已编写完成、可编译后，将结果写入 .claude/impl-result.json：
- 实现完成：写入 {\"status\": \"done\"}
- 无可执行任务：写入 {\"status\": \"no_task\"}

## 注意事项
- 不修改任务定义：只能修改 status 字段（设为 in_progress），不要改 name、description 等定义字段
- 不要修改 verifyPassed 或 retryCount
- 不要 git commit（由 harness 在审查通过后统一处理）
- 必须将结果写入 .claude/impl-result.json，harness 通过该文件判断会话结果"

        # ── Prompt B': 代码审查 ──────────────────────────────────
        VERIFY_PROMPT="你是一个严格的代码审查员。你的工作是审查一个纯逻辑功能的代码实现质量。
你不是实现者，你没有写这些代码，你对它没有感情。你的目标是找出问题，而不是找理由通过。

⚠️ 审查原则：
- 宁可误判为不通过，也不要放过问题
- 不要为实现者找借口（如「整体实现不错」「小问题可以接受」）
- 每个维度独立评分，不因其他维度表现好而放宽某个维度的标准
- 如果某个需求点完全未实现，相关维度直接 0 分

当前任务: ${NEXT_TASK}
任务描述: ${TASK_DESCRIPTION}
Dev Server URL: ${DEV_URL}
通过阈值: 每项 ≥ 7 分且总分 ≥ ${REVIEW_THRESHOLD}%

## 执行步骤

### Step 1: 理解需求
1. 读取 .claude/figma-tasks.json 获取当前任务信息（name、description）
2. 读取项目根目录的 CLAUDE.md（如果存在），了解项目规范
3. 理解任务的功能需求和预期行为

### Step 2: 审查实现代码
1. 通过 git diff HEAD~1（或 git status 查看变更文件）找到本次实现涉及的所有文件
2. 逐文件阅读实现代码
3. 如果任务涉及 UI 且 dev server 在运行，可通过 Chrome DevTools MCP 导航到相关页面检查运行时行为

### Step 3: 逐项评分
对以下每个维度独立打分（0-10 分），并列出具体问题。每个维度有不同权重，影响总分计算：

| 维度 | 权重 | 评分标准 |
|------|------|---------|
| correctness | 2.5 | 功能逻辑是否正确，是否满足任务描述中的所有需求点 |
| completeness | 2.0 | 是否实现了所有要求的功能，有无遗漏的需求点 |
| error_handling | 1.5 | 边界条件处理、错误处理、异常情况是否考虑周全 |
| code_quality | 1.5 | 代码可读性、命名规范、结构清晰度、是否遵循项目约定 |
| type_safety | 1.0 | TypeScript 类型是否正确，有无 any 滥用、类型断言不当 |
| integration | 1.5 | 与项目现有代码的集成是否合理，是否复用了已有组件/工具 |

### Step 4: 写入结果
将审查结果写入 .claude/review-result.json（harness 通过该文件读取评分），格式如下：

{
  \"passed\": false,
  \"scores\": {
    \"correctness\": 8,
    \"completeness\": 6,
    \"error_handling\": 7,
    \"code_quality\": 8,
    \"type_safety\": 9,
    \"integration\": 7
  },
  \"total_score\": 74,
  \"failed_dimensions\": [\"completeness\"],
  \"issues\": [
    \"completeness: 任务要求支持分页加载，但当前实现只获取了第一页数据\",
    \"error_handling: fetchUserData 没有处理网络超时的情况\",
    \"integration: 项目已有 useRequest hook，但这里自己写了 fetch 逻辑\"
  ]
}

评分规则：
- 各维度权重: correctness=2.5, completeness=2.0, error_handling=1.5, code_quality=1.5, type_safety=1.0, integration=1.5（权重总和=10.0）
- total_score = Σ(维度分数 × 维度权重) / (权重总和 × 10) × 100，四舍五入取整
- passed = true 当且仅当：total_score >= ${REVIEW_THRESHOLD} 且所有维度 >= 7
- failed_dimensions: 列出所有 < 7 分的维度
- issues: 列出所有具体问题，格式为「维度: 具体描述」
- 必须将结果写入 .claude/review-result.json，这是唯一的结果传递方式"

    fi

    # ── Prompt C/C': 修复（重试时使用，根据任务类型动态生成）──────
    # FIX_PROMPT 在验证/审查失败时动态生成，注入差异/问题描述

    # ================================================================
    # 阶段 1: 实现代码
    # ================================================================
    if $IS_DESIGN_TASK; then
        echo -e "  ${CYAN}[实现阶段]${NC} 启动 Claude 实现会话..."
    else
        echo -e "  ${CYAN}[实现阶段]${NC} 启动 Claude 实现会话... ${DIM}(纯逻辑任务)${NC}"
    fi

    run_claude_session "$IMPL_PROMPT"
    IMPL_ELAPSED=$RCS_ELAPSED

    $INTERRUPTED && break

    # 格式化耗时
    if [ "$IMPL_ELAPSED" -ge 60 ]; then
        IMPL_ELAPSED_STR="$((IMPL_ELAPSED / 60))m$((IMPL_ELAPSED % 60))s"
    else
        IMPL_ELAPSED_STR="${IMPL_ELAPSED}s"
    fi

    # 实现阶段超时检测
    if [ "$RCS_EXIT_CODE" -eq 124 ]; then
        echo -e "${RED}  -> 实现超时: $NEXT_TASK (${SESSION_TIMEOUT}s 上限)  耗时: ${IMPL_ELAPSED_STR}${NC}"
        jq 'map(if .status == "in_progress" then .status = "failed" | .lastError = "实现会话超时" else . end)' \
            "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
        if has_remaining_tasks && ! $INTERRUPTED; then
            echo -e "${DIM}  3s 后开始下一轮...${NC}"
            sleep 3
        fi
        continue
    fi

    # 读取结果文件判断实现状态
    IMPL_STATUS=""
    if [ -f "$IMPL_RESULT_FILE" ] && jq empty "$IMPL_RESULT_FILE" 2>/dev/null; then
        IMPL_STATUS=$(jq -r '.status // ""' "$IMPL_RESULT_FILE")
    fi

    if [ "$IMPL_STATUS" = "no_task" ]; then
        echo -e "${YELLOW}  -> 无可执行任务（依赖阻塞）${NC}"
        break
    fi

    if [ "$IMPL_STATUS" != "done" ]; then
        echo -e "${YELLOW}  -> 实现阶段未正常结束  耗时: ${IMPL_ELAPSED_STR}${NC}"
        jq 'map(if .status == "in_progress" then .status = "failed" | .lastError = "实现阶段异常退出" else . end)' \
            "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
        if has_remaining_tasks && ! $INTERRUPTED; then
            echo -e "${DIM}  3s 后开始下一轮...${NC}"
            sleep 3
        fi
        continue
    fi

    echo -e "${GREEN}  -> 实现完成  耗时: ${IMPL_ELAPSED_STR}${NC}"

    # ================================================================
    # 阶段 2: 验证/审查循环（harness 控制重试）
    # ================================================================
    RETRY_COUNT=0
    TASK_PASSED=false
    TOTAL_VERIFY_ELAPSED=0
    LAST_DIFFERENCES=""
    LAST_SCORES_JSON=""  # 上一轮评分 JSON，用于传递给验证和修复会话

    # 根据任务类型选择结果文件和标签
    if $IS_DESIGN_TASK; then
        RESULT_FILE="$VERIFY_RESULT_FILE"
        STAGE_LABEL="验证"
        DIFF_FIELD="differences"
        CURRENT_THRESHOLD="$VERIFY_THRESHOLD"
    else
        RESULT_FILE="$REVIEW_RESULT_FILE"
        STAGE_LABEL="审查"
        DIFF_FIELD="issues"
        CURRENT_THRESHOLD="$REVIEW_THRESHOLD"
    fi

    while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
        $INTERRUPTED && break

        if [ "$RETRY_COUNT" -eq 0 ]; then
            echo -e "  ${CYAN}[${STAGE_LABEL}阶段]${NC} 启动独立${STAGE_LABEL}会话..."
        else
            echo -e "  ${CYAN}[${STAGE_LABEL}阶段]${NC} 第 ${RETRY_COUNT} 次修复后重新${STAGE_LABEL}..."
        fi

        # 构建本轮验证 prompt（如果有上一轮评分，追加基线信息）
        CURRENT_VERIFY_PROMPT="$VERIFY_PROMPT"
        if [ -n "$LAST_SCORES_JSON" ] && [ "$RETRY_COUNT" -gt 0 ]; then
            CURRENT_VERIFY_PROMPT="${VERIFY_PROMPT}

## 上一轮评分基线（第 $((RETRY_COUNT)) 次修复前的评分）

上一轮各维度评分: ${LAST_SCORES_JSON}
上一轮发现的问题:
${LAST_DIFFERENCES}

⚠️ 评分一致性要求：
- 如果某个维度的实现与上一轮相比没有变化，该维度的评分应与上一轮保持一致（允许 ±1 分浮动）
- 如果修复引入了新问题（回归），对应维度应扣分并在差异中明确标注为「回归」
- 只有实际改善的维度才应提高分数，只有实际恶化的维度才应降低分数
- 不要因为本轮是重新评估就整体偏高或偏低，保持客观一致"
        fi

        # 运行验证/审查会话（每次前清理旧结果）
        rm -f "$RESULT_FILE"
        run_claude_session "$CURRENT_VERIFY_PROMPT"
        VERIFY_ELAPSED=$RCS_ELAPSED
        TOTAL_VERIFY_ELAPSED=$((TOTAL_VERIFY_ELAPSED + VERIFY_ELAPSED))

        $INTERRUPTED && break

        # 超时处理
        if [ "$RCS_EXIT_CODE" -eq 124 ]; then
            echo -e "${RED}  -> ${STAGE_LABEL}超时  ${NC}"
            RETRY_COUNT=$((RETRY_COUNT + 1))
            jq --argjson rc "$RETRY_COUNT" \
                'map(if .status == "in_progress" then .retryCount = $rc else . end)' \
                "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
            continue
        fi

        # 从结果文件读取 JSON，由脚本重新计算评分（不信任 LLM 的数学）
        if [ -f "$RESULT_FILE" ] && jq empty "$RESULT_FILE" 2>/dev/null; then
            LAST_DIFFERENCES=$(jq -r --arg field "$DIFF_FIELD" '.[$field] | join("\n")' "$RESULT_FILE")

            if $IS_DESIGN_TASK; then
                # 视觉验证：使用设计稿维度和权重
                VERIFIED_JSON=$(jq --argjson threshold "$CURRENT_THRESHOLD" '
                  {"layout":2.0,"spacing":1.5,"colors":1.5,"typography":1.0,"borders":0.5,"shadows":0.5,"icons_images":1.0,"completeness":2.0} as $w
                  | 10.0 as $wsum
                  | .scores as $s
                  | ($s | to_entries | map(.value * $w[.key]) | add) as $weighted
                  | (($weighted / ($wsum * 10) * 100) | round) as $total
                  | ($s | to_entries | map(select(.value < 7)) | map(.key)) as $failed
                  | ($total >= $threshold and ($failed | length) == 0) as $passed
                  | { total_score: $total, passed: $passed, failed_dimensions: $failed }
                ' "$RESULT_FILE")
            else
                # 代码审查：使用代码维度和权重
                VERIFIED_JSON=$(jq --argjson threshold "$CURRENT_THRESHOLD" '
                  {"correctness":2.5,"completeness":2.0,"error_handling":1.5,"code_quality":1.5,"type_safety":1.0,"integration":1.5} as $w
                  | 10.0 as $wsum
                  | .scores as $s
                  | ($s | to_entries | map(.value * $w[.key]) | add) as $weighted
                  | (($weighted / ($wsum * 10) * 100) | round) as $total
                  | ($s | to_entries | map(select(.value < 7)) | map(.key)) as $failed
                  | ($total >= $threshold and ($failed | length) == 0) as $passed
                  | { total_score: $total, passed: $passed, failed_dimensions: $failed }
                ' "$RESULT_FILE")
            fi

            TOTAL_SCORE=$(echo "$VERIFIED_JSON" | jq -r '.total_score')
            VERIFY_PASSED=$(echo "$VERIFIED_JSON" | jq -r '.passed')
            FAILED_DIMS=$(echo "$VERIFIED_JSON" | jq -r '.failed_dimensions | join(", ")')

            # 保存本轮评分 JSON（供下一轮验证和修复使用）
            LAST_SCORES_JSON=$(jq -c '.scores' "$RESULT_FILE" 2>/dev/null || echo "")

            # 打印评分详情
            echo -e "  ${BOLD}${STAGE_LABEL}评分:${NC}"
            if $IS_DESIGN_TASK; then
                jq -r '
                  {"layout":2.0,"spacing":1.5,"colors":1.5,"typography":1.0,"borders":0.5,"shadows":0.5,"icons_images":1.0,"completeness":2.0} as $w
                  | .scores | to_entries[] | "    \(.key): \(.value)/10 (×\($w[.key] // 1.0))"
                ' "$RESULT_FILE"
            else
                jq -r '
                  {"correctness":2.5,"completeness":2.0,"error_handling":1.5,"code_quality":1.5,"type_safety":1.0,"integration":1.5} as $w
                  | .scores | to_entries[] | "    \(.key): \(.value)/10 (×\($w[.key] // 1.0))"
                ' "$RESULT_FILE"
            fi
            echo -e "    ${BOLD}总分: ${TOTAL_SCORE}%${NC} (阈值: ${CURRENT_THRESHOLD}%)"
            if [ -n "$FAILED_DIMS" ] && [ "$FAILED_DIMS" != "" ]; then
                echo -e "    ${RED}未达标维度: ${FAILED_DIMS}${NC}"
            fi
        else
            echo -e "${YELLOW}  -> ${STAGE_LABEL}结果文件不存在或解析失败，视为未通过${NC}"
            VERIFY_PASSED=false
            LAST_DIFFERENCES="${STAGE_LABEL}结果文件不存在或解析失败"
        fi

        # 判定结果
        if [ "$VERIFY_PASSED" = "true" ]; then
            TASK_PASSED=true
            break
        fi

        # 未通过：递增 retryCount
        RETRY_COUNT=$((RETRY_COUNT + 1))
        jq --argjson rc "$RETRY_COUNT" \
            'map(if .status == "in_progress" then .retryCount = $rc else . end)' \
            "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"

        echo -e "  ${YELLOW}${STAGE_LABEL}未通过 (retry ${RETRY_COUNT}/${MAX_RETRIES})${NC}"

        if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
            break
        fi

        # 生成修复 prompt，根据任务类型注入不同内容
        echo -e "  ${CYAN}[修复阶段]${NC} 启动修复会话..."

        # 构建评分基线信息（两种任务类型共用）
        SCORES_CONTEXT=""
        if [ -n "$LAST_SCORES_JSON" ]; then
            SCORES_CONTEXT="
## 当前各维度评分

${LAST_SCORES_JSON}

⚠️ 防回归要求：
- 以上评分中 ≥ 7 分的维度是已达标维度，修复时必须保持这些维度不退步
- 重点修复 < 7 分的维度和下面列出的差异
- 如果修复某个问题可能影响已达标维度，请谨慎操作，确保不引入回归
"
        fi

        if $IS_DESIGN_TASK; then
            FIX_PROMPT="你现在处于 figma-impl 的 harness 执行阶段，需要修复一个 Figma 设计稿实现的视觉差异。
独立的视觉 QA 审查员已经检查了你的实现，发现以下问题：

当前任务: ${NEXT_TASK}
Dev Server URL: ${DEV_URL}
当前重试次数: ${RETRY_COUNT}/${MAX_RETRIES}
${SCORES_CONTEXT}
## QA 审查员发现的差异

${LAST_DIFFERENCES}

## 执行步骤

### Step 1: 理解问题
1. 读取 .claude/figma-tasks.json 获取当前任务信息
2. 读取项目根目录的 CLAUDE.md（如果存在），了解项目规范
3. 调用 Figma MCP 的 figma__get_design_context，传入 fileKey 和 nodeId，重新获取设计上下文
4. 调用 Figma MCP 的 figma__get_screenshot，传入 fileKey 和 nodeId，获取设计稿截图
5. 仔细阅读上面列出的每一个差异点

### Step 2: 针对性修复
针对上述每个差异点逐一修复代码。注意：
- 只修复上面列出的问题，不要做无关改动
- 确保修复不会引入新的视觉差异
- 确保代码可编译运行

### Step 3: 写入结果
修复完成后，将结果写入 .claude/fix-result.json：
- 写入 {\"status\": \"done\"}"
        else
            FIX_PROMPT="你现在处于 figma-impl 的 harness 执行阶段，需要修复一个纯逻辑功能实现中的代码问题。
独立的代码审查员已经检查了你的实现，发现以下问题：

当前任务: ${NEXT_TASK}
任务描述: ${TASK_DESCRIPTION}
Dev Server URL: ${DEV_URL}
当前重试次数: ${RETRY_COUNT}/${MAX_RETRIES}
${SCORES_CONTEXT}
## 代码审查员发现的问题

${LAST_DIFFERENCES}

## 执行步骤

### Step 1: 理解问题
1. 读取 .claude/figma-tasks.json 获取当前任务信息
2. 读取项目根目录的 CLAUDE.md（如果存在），了解项目规范
3. 仔细阅读上面列出的每一个问题点
4. 阅读相关代码，理解问题上下文

### Step 2: 针对性修复
针对上述每个问题点逐一修复代码。注意：
- 只修复上面列出的问题，不要做无关改动
- 确保修复不会引入新的问题
- 确保代码可编译运行
- 注意边界条件和错误处理

### Step 3: 写入结果
修复完成后，将结果写入 .claude/fix-result.json：
- 写入 {\"status\": \"done\"}"
        fi

        rm -f "$FIX_RESULT_FILE"
        run_claude_session "$FIX_PROMPT"
        FIX_ELAPSED=$RCS_ELAPSED
        TOTAL_VERIFY_ELAPSED=$((TOTAL_VERIFY_ELAPSED + FIX_ELAPSED))

        $INTERRUPTED && break

        if [ "$RCS_EXIT_CODE" -eq 124 ]; then
            echo -e "${RED}  -> 修复超时${NC}"
        elif [ -f "$FIX_RESULT_FILE" ] && [ "$(jq -r '.status // ""' "$FIX_RESULT_FILE" 2>/dev/null)" = "done" ]; then
            echo -e "${GREEN}  -> 修复完成${NC}"
        else
            echo -e "${YELLOW}  -> 修复阶段未正常结束${NC}"
        fi

    done  # end verify/fix loop

    $INTERRUPTED && break

    # 格式化总耗时
    TOTAL_ELAPSED=$((IMPL_ELAPSED + TOTAL_VERIFY_ELAPSED))
    if [ "$TOTAL_ELAPSED" -ge 60 ]; then
        TOTAL_ELAPSED_STR="$((TOTAL_ELAPSED / 60))m$((TOTAL_ELAPSED % 60))s"
    else
        TOTAL_ELAPSED_STR="${TOTAL_ELAPSED}s"
    fi

    # 最终判定
    if [ "$TASK_PASSED" = true ]; then
        # 验证通过：更新状态 + git commit
        jq 'map(if .status == "in_progress" then .status = "done" | .verifyPassed = true | .completedAt = (now | strftime("%Y-%m-%dT%H:%M:%SZ")) else . end)' \
            "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"

        # git commit（提交所有变更，含 figma-tasks.json 的状态更新）
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            git add -A && git commit -m "feat: 实现 ${NEXT_TASK} - Figma设计稿还原" 2>/dev/null || true
        fi

        echo -e "${GREEN}  -> 完成: $NEXT_TASK  耗时: ${TOTAL_ELAPSED_STR}  重试: ${RETRY_COUNT}${NC}"
    else
        # 验证失败：标记 failed
        ESCAPED_DIFF=$(echo "$LAST_DIFFERENCES" | head -c 500 | jq -Rs .)
        jq --argjson rc "$RETRY_COUNT" --argjson err "$ESCAPED_DIFF" \
            'map(if .status == "in_progress" then .status = "failed" | .retryCount = $rc | .lastError = $err else . end)' \
            "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"

        echo -e "${RED}  -> 失败: $NEXT_TASK (验证未通过, 重试 ${RETRY_COUNT}/${MAX_RETRIES})  耗时: ${TOTAL_ELAPSED_STR}${NC}"
    fi

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
