#!/bin/bash

# 定义项目目录和配置文件路径
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$SCRIPT_DIR/nexus-node"
CONFIG_FILE="$PROJECT_ROOT_DIR/data/node_config.conf"

# 函数：检查并安装依赖
function check_and_install_dependencies() {
    echo "检查并安装依赖..."

    # 检查并安装 Rust 和 Cargo
    if ! command -v cargo &> /dev/null; then
        echo "Rust 和 Cargo 未安装，正在安装..."
        curl https://sh.rustup.rs -sSf | sh -s -- -y
        # 在脚本内部立即加载 Cargo 的环境变量 ，使其对当前脚本会话生效
        source "$HOME/.cargo/env"
        echo "Rust 和 Cargo 安装完成。"
    else
        echo "Rust 和 Cargo 已安装。"
    fi

    # 检查并安装构建工具 (适用于 Debian/Ubuntu)
    if ! command -v make &> /dev/null || ! command -v gcc &> /dev/null; then
        echo "构建工具未安装，正在安装..."
        sudo apt-get update
        sudo apt-get install -y build-essential pkg-config libssl-dev clang cmake
        echo "构建工具安装完成。"
    else
        echo "构建工具已安装。"
    fi

    # 检查并安装 tmux
    if ! command -v tmux &> /dev/null; then
        echo "tmux 未安装，正在安装..."
        sudo apt-get install -y tmux
        echo "tmux 安装完成。"
    else
        echo "tmux 已安装。"
    fi
}

# 函数：显示主菜单
function show_menu() {
    clear
    echo "========== Nexus CLI 节点管理 =========="
    echo "1. 安装/更新并启动节点"
    echo "2. 停止并删除节点"
    echo "3. 查看节点日志"
    echo "4. 显示当前配置"
    echo "5. 退出"
    echo "========================================"
}

# 函数：安装/更新并启动节点
function install_and_start_node() {
    echo "正在安装/更新并启动节点..."
    check_and_install_dependencies

    # 克隆或更新仓库
    if [ -d "$PROJECT_ROOT_DIR/nexus-cli" ]; then
        echo "检测到现有仓库，正在更新..."
        cd "$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
        git pull
    else
        echo "克隆 Nexus CLI 仓库..."
        mkdir -p "$PROJECT_ROOT_DIR"
        cd "$PROJECT_ROOT_DIR"
        git clone https://github.com/nexus-xyz/nexus-cli.git
        # 创建新的目录结构
        mkdir -p "$PROJECT_ROOT_DIR/data"
        mkdir -p "$PROJECT_ROOT_DIR/logs"
        cd "$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
    fi

    echo "编译 Nexus CLI..."
    cargo build --release

    read -rp "请输入您的 Node ID: " NODE_ID
    if [ -z "$NODE_ID" ]; then
        echo "Node ID 不能为空 ，操作取消。"
        return
    fi

    read -rp "请输入节点使用的最大CPU线程数 (例如: 2, 4, 8): " MAX_THREADS
    if ! [[ "$MAX_THREADS" =~ ^[0-9]+$ ]] || [ "$MAX_THREADS" -eq 0 ]; then
        echo "线程数必须是大于0的整数，操作取消。"
        return
    fi

    # 每次启动前，都覆盖写入最新的配置信息到文件
    echo "NODE_ID=$NODE_ID" > "$CONFIG_FILE"
    echo "MAX_THREADS=$MAX_THREADS" >> "$CONFIG_FILE"

    # 检查是否有正在运行的会话，如果有则杀死
    if tmux has-session -t nexus_node &> /dev/null; then
        echo "检测到旧的 tmux 会话，正在停止..."
        tmux kill-session -t nexus_node
        sleep 1 # 等待会话完全关闭
    fi

    echo "在 tmux 会话中启动节点..."
    # 启动 tmux 会话并在其中运行节点
    tmux new-session -d -s nexus_node "$PROJECT_ROOT_DIR/nexus-cli/clients/cli/target/release/nexus-network start --node-id $NODE_ID --max-threads $MAX_THREADS > $PROJECT_ROOT_DIR/logs/nexus_node.log 2>&1"

    echo "节点已在后台启动。您可以通过 'tmux attach -t nexus_node' 查看日志。"
    echo "请注意：您输入的线程数为 $MAX_THREADS。"
}

# 函数：停止并删除节点
function stop_and_delete_node() {
    echo "正在停止并删除节点..."
    # 检查并杀死 tmux 会话
    if tmux has-session -t nexus_node &> /dev/null; then
        echo "检测到 nexus_node tmux 会话，正在停止..."
        tmux kill-session -t nexus_node
        echo "tmux 会话已停止。"
    else
        echo "没有找到正在运行的 nexus_node tmux 会话。"
    fi

    # 删除项目目录
    if [ -d "$PROJECT_ROOT_DIR" ]; then
        read -rp "确定要删除整个项目目录 ($PROJECT_ROOT_DIR) 吗？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            echo "正在删除项目目录..."
            rm -rf "$PROJECT_ROOT_DIR"
            echo "项目目录已删除。"
        else
            echo "删除操作已取消。"
        fi
    else
        echo "项目目录 $PROJECT_ROOT_DIR 不存在。"
    fi
    echo "节点清理操作完成。"
}

# 函数：查看节点日志
function view_node_logs() {
    echo "正在查看节点日志..."
    if [ -f "$PROJECT_ROOT_DIR/logs/nexus_node.log" ]; then
        echo "日志文件内容 (按 Ctrl+C 退出):"
        tail -f "$PROJECT_ROOT_DIR/logs/nexus_node.log"
    else
        echo "日志文件 $PROJECT_ROOT_DIR/logs/nexus_node.log 不存在。请先启动节点。"
    fi
}

# 函数：显示当前配置
function show_current_config() {
    echo "--- 当前节点配置 ---"
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
        echo "----------------------"
        echo "注意：这是您上一次启动节点时保存的配置。"
    else
        echo "未找到配置文件。请先启动一次节点。"
        echo "----------------------"
    fi
}

# 主循环
while true; do
    show_menu
    read -rp "请选择操作: " choice
    case "$choice" in
        1) install_and_start_node ;;
        2) stop_and_delete_node ;;
        3) view_node_logs ;;
        4) show_current_config ;;
        5) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" ;;
    esac
    read -rp "按 Enter 键继续..."
done
