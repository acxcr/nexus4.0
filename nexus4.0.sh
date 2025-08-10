#!/bin/bash

# ==============================================================================
# 全局变量定义
# ==============================================================================

# 脚本和项目文件的根目录，默认在脚本所在目录下创建
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$SCRIPT_DIR/nexus-node"

# 配置文件路径
CONFIG_FILE="$PROJECT_ROOT_DIR/data/node_configs.conf"

# 源码和可执行文件的正确路径
NODE_SOURCE_DIR="$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
NODE_EXECUTABLE_PATH="$NODE_SOURCE_DIR/target/release/nexus-network"

# --- 核心安全机制：为本脚本的所有tmux操作指定一个独立的Socket ---
# 这将确保我们的脚本使用的tmux环境与系统里其他tmux会话 (如 'fort') 完全隔离
TMUX_SOCKET_NAME="nexus_script_socket"
TMUX_CMD="tmux -L $TMUX_SOCKET_NAME"


# ==============================================================================
# 功能函数定义
# ==============================================================================

# 函数：检查并安装所有官方要求的依赖
function check_and_install_dependencies() {
    echo "检查并安装所有官方要求的依赖..."
    NEEDS_UPDATE=false
    # 检查核心构建工具和关键依赖
    if ! dpkg -s build-essential pkg-config libssl-dev git protobuf-compiler >/dev/null 2>&1; then
        echo "检测到缺失核心构建工具或protobuf-compiler，准备安装..."
        NEEDS_UPDATE=true
    fi
    if [ "$NEEDS_UPDATE" = true ]; then
        sudo apt-get update
        sudo apt-get install -y build-essential pkg-config libssl-dev git protobuf-compiler
    else
        echo "核心构建依赖均已安装。"
    fi
    # 检查并安装 Rust
    if ! command -v cargo &> /dev/null; then
        echo "Rust 未安装，正在安装..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    else
        echo "Rust 已安装 。"
    fi
    # 检查并安装 tmux
    if ! command -v tmux &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y tmux
    else
        echo "tmux 已安装。"
    fi
}

# 函数：显示主菜单
function show_menu() {
    clear
    echo "========== Nexus 多节点管理 (生产环境安全版) =========="
    echo "1. 安装/更新并启动所有节点"
    echo "2. 停止所有由本脚本启动的节点"
    echo "3. 查看节点实时界面"
    echo "4. 查看已保存的节点配置"
    echo "5. 彻底卸载和清理 (仅限本脚本创建的内容)"
    echo "6. 退出"
    echo "========================================================"
}

# 函数：安装/更新并启动节点
function install_and_start_node() {
    echo "正在安装/更新节点程序..."
    check_and_install_dependencies

    if [ -d "$PROJECT_ROOT_DIR/nexus-cli" ]; then
        echo "检测到现有仓库，正在更新..."
        cd "$PROJECT_ROOT_DIR/nexus-cli"; git pull
    else
        echo "克隆 Nexus CLI 仓库..."; mkdir -p "$PROJECT_ROOT_DIR"; cd "$PROJECT_ROOT_DIR"
        git clone https://github.com/nexus-xyz/nexus-cli.git
        mkdir -p "$PROJECT_ROOT_DIR/data"; mkdir -p "$PROJECT_ROOT_DIR/logs"
    fi

    echo "进入节点源码目录: $NODE_SOURCE_DIR"; cd "$NODE_SOURCE_DIR"
    echo "正在从源码编译节点程序..."; if ! command -v cargo &> /dev/null; then source "$HOME/.cargo/env"; fi
    cargo build --release

    if [ ! -f "$NODE_EXECUTABLE_PATH" ]; then
        echo "错误：编译失败！未在 $NODE_EXECUTABLE_PATH 找到可执行文件 。"; return
    fi

    echo "请输入您的所有 Node ID，用空格隔开，然后按 Enter:"; read -ra NODE_IDS
    if [ ${#NODE_IDS[@]} -eq 0 ]; then echo "未输入任何 Node ID，操作取消。"; return; fi
    printf "%s\n" "${NODE_IDS[@]}" > "$CONFIG_FILE"
    echo "已将 ${#NODE_IDS[@]} 个 Node ID 保存到配置中。"
    CPU_CORES=$(nproc); THREADS_PER_NODE=$((CPU_CORES / ${#NODE_IDS[@]}))
    if [ "$THREADS_PER_NODE" -eq 0 ]; then THREADS_PER_NODE=1; fi
    echo "检测到 $CPU_CORES 个CPU核心，将为每个节点分配 $THREADS_PER_NODE 个线程。"

    for i in "${!NODE_IDS[@]}"; do
        NODE_ID=${NODE_IDS[$i]}; SESSION_NAME="nexus_node_$((i+1))"
        LOG_FILE="$PROJECT_ROOT_DIR/logs/${SESSION_NAME}.log"
        if $TMUX_CMD has-session -t "$SESSION_NAME" &> /dev/null; then
            $TMUX_CMD kill-session -t "$SESSION_NAME"; sleep 1
        fi
        echo "正在为 Node ID: $NODE_ID 启动节点 (会话: $SESSION_NAME)..."
        $TMUX_CMD new-session -d -s "$SESSION_NAME" \
            "$NODE_EXECUTABLE_PATH start --node-id $NODE_ID --max-threads $THREADS_PER_NODE > $LOG_FILE 2>&1"
    done
    echo "所有节点实例均已在后台的独立环境中启动！"
}

# 函数：停止所有由本脚本启动的节点
function stop_all_nodes() {
    echo "正在停止所有由本脚本创建的 nexus_node_* 会话..."
    $TMUX_CMD ls | grep "nexus_node_" | cut -d: -f1 | xargs -r -I{} $TMUX_CMD kill-session -t {}
    echo "所有相关节点会话已停止。系统其他tmux会话不受影响。"
}

# 函数：查看节点实时界面
function view_node_interface() {
    printf "%-10s %-15s %-10s %-20s\n" "组" "节点ID" "状态" "已运行时间"
    echo "==============================================================="
    if [ ! -f "$CONFIG_FILE" ]; then echo "错误：未找到配置文件。"; return; fi
    mapfile -t SAVED_IDS < "$CONFIG_FILE"
    if ! $TMUX_CMD ls | grep -q "nexus_node_"; then echo "没有检测到由本脚本启动的节点。"; return; fi
    for i in "${!SAVED_IDS[@]}"; do
        GROUP_NUM=$((i+1)); NODE_ID=${SAVED_IDS[$i]}; SESSION_NAME="nexus_node_$GROUP_NUM"
        if $TMUX_CMD has-session -t "$SESSION_NAME" &> /dev/null; then
            STATUS="✅ 运行中"; CREATION_TIMESTAMP=$($TMUX_CMD display-message -p -t "$SESSION_NAME" '#{session_created}'); NOW_TIMESTAMP=$(date +%s)
            UPTIME_SECONDS=$((NOW_TIMESTAMP - CREATION_TIMESTAMP)); UPTIME_FORMATTED=$(printf '%dd-%dh-%dm-%ds' $((UPTIME_SECONDS/86400)) $((UPTIME_SECONDS%86400/3600)) $((UPTIME_SECONDS%3600/60)) $((UPTIME_SECONDS%60)))
        else
            STATUS="❌ 已停止"; UPTIME_FORMATTED="N/A"
        fi
        printf "%-10s %-15s %-10s %-20s\n" "组 $GROUP_NUM" "$NODE_ID" "$STATUS" "$UPTIME_FORMATTED"
    done
    echo "==============================================================="
    read -rp "请输入您想查看的组数字: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo "错误：请输入一个有效的数字。"; return; fi
    SESSION_NAME="nexus_node_$choice"
    if $TMUX_CMD has-session -t "$SESSION_NAME" &> /dev/null; then
        echo "正在进入实时界面... 按 Ctrl+B 然后按 D 键可安全分离并返回。"
        sleep 2; $TMUX_CMD attach-session -t "$SESSION_NAME"
    else
        echo "错误：组 $choice 的节点当前未在运行。";
    fi
}

# 函数：显示当前配置
function show_current_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "--- 已保存的 Node ID 列表 ---"; cat "$CONFIG_FILE"; echo "-----------------------------"
    else
        echo "未找到配置文件。请先运行选项1来设置。";
    fi
}

# 函数：彻底卸载和清理
function uninstall_and_clean() {
    read -rp "这将停止所有相关节点并删除 $PROJECT_ROOT_DIR 目录，确定吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        stop_all_nodes
        echo "正在删除项目目录: $PROJECT_ROOT_DIR"
        rm -rf "$PROJECT_ROOT_DIR"
        echo "卸载完成。"
    else
        echo "操作已取消。";
    fi
}

# ==============================================================================
# 主循环
# ==============================================================================
while true; do
    show_menu
    read -rp "请选择操作: " choice
    case "$choice" in
        1) install_and_start_node ;;
        2) stop_all_nodes ;;
        3) view_node_interface ;;
        4) show_current_config ;;
        5) uninstall_and_clean ;;
        6) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" ;;
    esac
    read -rp "按 Enter 键继续..."
done
