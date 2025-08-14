#!/bin/bash

# ==============================================================================
# 全局变量定义
# ==============================================================================
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$SCRIPT_DIR/nexus-node"
CONFIG_FILE="$PROJECT_ROOT_DIR/data/node_configs.conf"
# 日志目录仍然保留，用于捕获启动时的错误，但主要查看方式已改变
LOGS_DIR="$PROJECT_ROOT_DIR/logs"

# ==============================================================================
# 功能函数定义
# ==============================================================================

# 函数：检查并安装依赖 (无变动)
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
    echo "========== Nexus 多节点管理 (TUI 适配版) =========="
    echo "1. 安装/更新并启动所有节点"
    echo "2. 停止所有节点"
    echo "3. 进入节点终端 (查看动画页面)"
    echo "4. 查看已保存的节点配置"
    echo "5. 彻底卸载和清理"
    echo "6. 退出"
    echo "================================================="
}

# 函数：安装/更新并启动所有节点
function install_and_start_node() {
    echo "正在安装/更新并启动节点..."; check_and_install_dependencies
    
    mkdir -p "$PROJECT_ROOT_DIR" "$LOGS_DIR" "$PROJECT_ROOT_DIR/data"

    if [ -d "$PROJECT_ROOT_DIR/nexus-cli" ]; then
        echo "检测到现有仓库，正在更新..."; cd "$PROJECT_ROOT_DIR/nexus-cli" && git pull
    else
        echo "克隆 Nexus CLI 仓库..."; git clone https://github.com/nexus-xyz/nexus-cli.git "$PROJECT_ROOT_DIR/nexus-cli"
    fi
    
    cd "$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
    echo "编译 Nexus CLI (这可能需要一些时间 )..."; cargo build --release
    
    local cli_path="$PROJECT_ROOT_DIR/nexus-cli/clients/cli/target/release/nexus-network"
    if [ ! -f "$cli_path" ]; then echo "错误：编译失败！找不到可执行文件: $cli_path"; return 1; fi
    
    echo "请输入您要运行的所有 Node ID，用空格隔开，然后按 Enter:"; read -ra NODE_IDS
    if [ ${#NODE_IDS[@]} -eq 0 ]; then echo "未输入任何 Node ID，操作取消。"; return; fi
    
    printf "%s\n" "${NODE_IDS[@]}" > "$CONFIG_FILE"; echo "已将 ${#NODE_IDS[@]} 个 Node ID 保存到配置中。"
    
    local cpu_cores=$(nproc); local threads_per_node=$((cpu_cores / ${#NODE_IDS[@]}))
    if [ "$threads_per_node" -eq 0 ]; then threads_per_node=1; fi
    echo "检测到 $cpu_cores 个CPU核心，将为每个节点分配 $threads_per_node 个线程。"
    
    echo "正在停止所有旧的 nexus_node_* 会话..."; 
    tmux ls 2>/dev/null | grep "nexus_node_" | cut -d: -f1 | xargs -r -I{} tmux kill-session -t {}
    sleep 1
    
    for i in "${!NODE_IDS[@]}"; do
        local node_id=${NODE_IDS[$i]}
        local session_name="nexus_node_$((i+1))"
        # 【重要改动】这里不再重定向到日志文件，因为是 TUI 界面
        echo "正在为 Node ID: $node_id 启动节点 (会话: $session_name)..."
        tmux new-session -d -s "$session_name" "$cli_path start --node-id $node_id --max-threads $threads_per_node"
    done
    
    echo "所有节点实例均已在后台启动！"
    echo "你可以使用选项 '3' 来进入任一节点的终端查看运行情况。"
}

# 函数：停止所有节点 (无变动)
function stop_all_nodes() {
    echo "正在停止所有由本脚本启动的节点...";
    if ! tmux ls 2>/dev/null | grep -q "nexus_node_"; then echo "没有检测到正在运行的节点会话。"; return; fi
    tmux ls | grep "nexus_node_" | cut -d: -f1 | xargs -r -I{} tmux kill-session -t {}
    echo "所有节点会话已停止。"
}

# 函数：【核心修正】进入节点终端
function view_node_logs() {
    if ! tmux ls 2>/dev/null | grep -q "nexus_node_"; then echo "没有检测到正在运行的节点会话。"; return; fi
    if [ ! -f "$CONFIG_FILE" ]; then echo "错误：找不到配置文件。请先运行一次启动选项。"; return; fi
    
    echo "--- 请选择要进入的节点终端 ---"; 
    mapfile -t SAVED_IDS < "$CONFIG_FILE"
    for i in "${!SAVED_IDS[@]}"; do 
        echo "$((i+1)). 节点 $((i+1)) (ID: ${SAVED_IDS[$i]})"; 
    done
    echo "--------------------------------"; 
    read -rp "请输入节点数字: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SAVED_IDS[@]} ]; then echo "无效输入。"; return; fi
    
    local session_name="nexus_node_$choice"
    
    # 检查会话是否存在
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "错误：会话 $session_name 不存在。可能已经崩溃或被手动关闭。"
        echo "你可以尝试重启所有节点。"
        return
    fi

    echo "正在进入会话 $session_name ... (按 Ctrl+b 然后按 d 键可以分离会话并返回菜单)"
    # 等待用户按键，给用户时间阅读提示信息
    read -n 1 -s -r -p "按任意键继续..."
    # 使用 tmux attach-session (或简写 attach) 进入会话
    tmux attach -t "$session_name"
}

# 函数：显示当前配置 (无变动)
function show_current_config() {
    echo "--- 已保存的 Node ID 列表 ---"
    if [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else echo "未找到配置文件。请先运行一次启动选项。"; fi
    echo "-----------------------------"
}

# 函数：彻底卸载和清理 (无变动)
function uninstall_and_clean() {
    stop_all_nodes
    if [ -d "$PROJECT_ROOT_DIR" ]; then
        read -rp "警告：此操作将删除整个项目目录 ($PROJECT_ROOT_DIR)，包括所有配置。确定吗？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then echo "正在删除项目目录..."; rm -rf "$PROJECT_ROOT_DIR"; echo "项目目录已删除。"; else echo "删除操作已取消。"; fi
    else
        echo "项目目录 $PROJECT_ROOT_DIR 不存在。"
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
        3) view_node_logs ;;
        4) show_current_config ;;
        5) uninstall_and_clean ;;
        6) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" ;;
    esac
    # 在 attach 返回后，需要清屏并提示返回菜单
    clear
    echo "已从 tmux 会话返回。"
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
