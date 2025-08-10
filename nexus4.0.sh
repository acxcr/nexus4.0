#!/bin/bash

# ==============================================================================
# 全局变量定义
# ==============================================================================
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$SCRIPT_DIR/nexus-node"
CONFIG_FILE="$PROJECT_ROOT_DIR/data/node_configs.conf"

# ==============================================================================
# 功能函数定义
# ==============================================================================

# 函数：检查并安装依赖 (已修正，包含所有官方依赖)
function check_and_install_dependencies() {
    echo "检查并安装依赖..."
    if ! command -v cargo &> /dev/null; then
        echo "Rust 和 Cargo 未安装，正在安装..."; curl https://sh.rustup.rs -sSf | sh -s -- -y; source "$HOME/.cargo/env"; echo "Rust 和 Cargo 安装完成 。"
    else
        echo "Rust 和 Cargo 已安装。"
    fi

    REQUIRED_PACKAGES="build-essential pkg-config libssl-dev clang cmake git protobuf-compiler tmux"
    PACKAGES_TO_INSTALL=""
    for pkg in $REQUIRED_PACKAGES; do
        # 使用 dpkg-query 更可靠地检查包状态
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL $pkg"
        fi
    done

    if [ -n "$PACKAGES_TO_INSTALL" ]; then
        echo "检测到以下缺失的依赖:$PACKAGES_TO_INSTALL"; echo "正在准备安装..."
        sudo apt-get update; sudo apt-get install -y $PACKAGES_TO_INSTALL
        echo "所有缺失的依赖已安装完成。"
    else
        echo "所有必需的依赖均已安装。"
    fi
}

# 函数：显示主菜单
function show_menu() {
    clear
    echo "========== Nexus 多节点管理 (最终修正版) =========="
    echo "1. 安装/更新并启动所有节点"
    echo "2. 停止所有节点"
    echo "3. 查看节点日志"
    echo "4. 查看已保存的节点配置"
    echo "5. 彻底卸载和清理"
    echo "6. 退出"
    echo "================================================="
}

# 函数：安装/更新并启动所有节点
function install_and_start_node() {
    echo "正在安装/更新并启动节点..."; check_and_install_dependencies
    if [ -d "$PROJECT_ROOT_DIR/nexus-cli" ]; then
        echo "检测到现有仓库，正在更新..."; cd "$PROJECT_ROOT_DIR/nexus-cli/clients/cli"; git pull
    else
        echo "克隆 Nexus CLI 仓库..."; mkdir -p "$PROJECT_ROOT_DIR"; cd "$PROJECT_ROOT_DIR"
        git clone https://github.com/nexus-xyz/nexus-cli.git
        mkdir -p "$PROJECT_ROOT_DIR/data"; mkdir -p "$PROJECT_ROOT_DIR/logs"
        cd "$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
    fi
    echo "编译 Nexus CLI..."; cargo build --release
    if [ ! -f "$PROJECT_ROOT_DIR/nexus-cli/clients/cli/target/release/nexus-network" ]; then echo "错误：编译失败！"; return; fi
    echo "请输入您要运行的所有 Node ID ，用空格隔开，然后按 Enter:"; read -ra NODE_IDS
    if [ ${#NODE_IDS[@]} -eq 0 ]; then echo "未输入任何 Node ID，操作取消。"; return; fi
    printf "%s\n" "${NODE_IDS[@]}" > "$CONFIG_FILE"; echo "已将 ${#NODE_IDS[@]} 个 Node ID 保存到配置中。"
    CPU_CORES=$(nproc); THREADS_PER_NODE=$((CPU_CORES / ${#NODE_IDS[@]}))
    if [ "$THREADS_PER_NODE" -eq 0 ]; then THREADS_PER_NODE=1; fi
    echo "检测到 $CPU_CORES 个CPU核心，将为每个节点分配 $THREADS_PER_NODE 个线程。"
    echo "正在停止所有旧的 nexus_node_* 会话..."; tmux ls | grep "nexus_node_" | cut -d: -f1 | xargs -r -I{} tmux kill-session -t {}; sleep 1
    for i in "${!NODE_IDS[@]}"; do
        NODE_ID=${NODE_IDS[$i]}; SESSION_NAME="nexus_node_$((i+1))"
        LOG_FILE="$PROJECT_ROOT_DIR/logs/${SESSION_NAME}.log"
        echo "正在为 Node ID: $NODE_ID 启动节点 (会话: $SESSION_NAME)..."
        tmux new-session -d -s "$SESSION_NAME" \
            "$PROJECT_ROOT_DIR/nexus-cli/clients/cli/target/release/nexus-network start --node-id $NODE_ID --max-threads $THREADS_PER_NODE" > "$LOG_FILE" 2>&1
    done
    echo "所有节点实例均已在后台启动！"
}

# 函数：停止所有节点
function stop_all_nodes() {
    echo "正在停止所有由本脚本启动的节点...";
    if ! tmux ls | grep -q "nexus_node_"; then echo "没有检测到正在运行的节点会话。"; return; fi
    tmux ls | grep "nexus_node_" | cut -d: -f1 | xargs -r -I{} tmux kill-session -t {}
    echo "所有节点会话已停止。"
}

# 函数：查看节点日志
function view_node_logs() {
    if ! tmux ls | grep -q "nexus_node_"; then echo "没有检测到正在运行的节点会话。"; return; fi
    echo "--- 请选择要查看日志的节点 ---"; mapfile -t SAVED_IDS < "$CONFIG_FILE"
    for i in "${!SAVED_IDS[@]}"; do echo "$((i+1)). 节点组 $((i+1)) (ID: ${SAVED_IDS[$i]})"; done
    echo "--------------------------------"; read -rp "请输入组数字: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SAVED_IDS[@]} ]; then echo "无效输入。"; return; fi
    SESSION_NAME="nexus_node_$choice"; LOG_FILE="$PROJECT_ROOT_DIR/logs/${SESSION_NAME}.log"
    if [ -f "$LOG_FILE" ]; then echo "正在显示 $LOG_FILE 的内容 (按 Ctrl+C 退出):"; tail -f "$LOG_FILE"; else echo "错误：找不到日志文件 $LOG_FILE。"; fi
}

# 函数：显示当前配置
function show_current_config() {
    echo "--- 已保存的 Node ID 列表 ---"
    if [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else echo "未找到配置文件。请先启动一次节点。"; fi
    echo "-----------------------------"
}

# 函数：彻底卸载和清理
function uninstall_and_clean() {
    stop_all_nodes
    if [ -d "$PROJECT_ROOT_DIR" ]; then
        read -rp "确定要删除整个项目目录 ($PROJECT_ROOT_DIR) 吗？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then echo "正在删除项目目录..."; rm -rf "$PROJECT_ROOT_DIR"; echo "项目目录已删除。"; else echo "删除操作已取消。"; fi
    else
        echo "项目目录 $PROJECT_ROOT_DIR 不存在。"
    fi
}

# 主循环
while true; do
    show_menu
    read -rp "请选择操作: " choice
    case "$choice" in
        1) install_and_start_node ;;
        2) stop_all_nodes ;;
        3) view_node_logs ;;
        4) show_current_config ;;
        5) uninstall_and_clean; ;;
        6) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" ;;
    esac
    read -rp "按 Enter 键继续..."
done
