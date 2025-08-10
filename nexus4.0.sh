#!/bin/bash

# 全局变量
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$SCRIPT_DIR/nexus-node"
CONFIG_FILE="$PROJECT_ROOT_DIR/data/node_configs.conf"
# 源码和可执行文件的路径 (我们最初的判断是正确的)
NODE_SOURCE_DIR="$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
NODE_EXECUTABLE_PATH="$NODE_SOURCE_DIR/target/release/nexus-network"

# 函数：检查并安装所有官方要求的依赖
function check_and_install_dependencies() {
    echo "检查并安装所有官方要求的依赖..."
    # 标记是否需要更新apt
    NEEDS_UPDATE=false

    # 检查核心构建工具
    if ! dpkg -s build-essential pkg-config libssl-dev git >/dev/null 2>&1; then
        echo "正在安装核心构建工具..."
        NEEDS_UPDATE=true
    fi
    
    # --- 关键修正：检查并安装 protobuf-compiler ---
    if ! command -v protoc &> /dev/null; then
        echo "检测到缺失关键依赖：protobuf-compiler。正在准备安装..."
        NEEDS_UPDATE=true
    fi

    # 如果需要，则先更新apt
    if [ "$NEEDS_UPDATE" = true ]; then
        sudo apt-get update
        sudo apt-get install -y build-essential pkg-config libssl-dev git protobuf-compiler
        echo "核心依赖安装完成。"
    else
        echo "所有核心依赖均已安装。"
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
        sudo apt-get update # 可能需要再次更新
        sudo apt-get install -y tmux
    else
        echo "tmux 已安装。"
    fi
}

# 函数：显示主菜单
function show_menu() {
    clear
    echo "========== Nexus 多节点管理 (源码编译版) =========="
    echo "1. 安装/更新并启动所有节点"
    echo "2. 停止所有节点"
    echo "3. 查看节点实时界面"
    echo "4. 查看已保存的节点配置"
    echo "5. 彻底卸载和清理"
    echo "6. 退出"
    echo "========================================================"
}

# 函数：安装/更新并启动节点
function install_and_start_node() {
    echo "正在安装/更新节点程序..."
    check_and_install_dependencies

    # 克隆或更新仓库
    if [ -d "$PROJECT_ROOT_DIR/nexus-cli" ]; then
        echo "检测到现有仓库，正在更新..."
        cd "$PROJECT_ROOT_DIR/nexus-cli"
        git pull
    else
        echo "克隆 Nexus CLI 仓库..."
        mkdir -p "$PROJECT_ROOT_DIR"
        cd "$PROJECT_ROOT_DIR"
        git clone https://github.com/nexus-xyz/nexus-cli.git
        mkdir -p "$PROJECT_ROOT_DIR/data"
        mkdir -p "$PROJECT_ROOT_DIR/logs"
    fi

    # 进入正确的源码目录进行编译
    echo "进入节点源码目录: $NODE_SOURCE_DIR"
    cd "$NODE_SOURCE_DIR"

    echo "正在从源码编译节点程序 (这可能需要一些时间 )..."
    # 确保cargo命令在当前shell可用
    if ! command -v cargo &> /dev/null; then source "$HOME/.cargo/env"; fi
    cargo build --release

    # 检查编译是否成功
    if [ ! -f "$NODE_EXECUTABLE_PATH" ]; then
        echo "错误：编译失败！未在 $NODE_EXECUTABLE_PATH 找到可执行文件。"
        echo "请检查上面的编译日志寻找错误原因。"
        return
    fi

    # ...后续逻辑完全不变...
    echo "请输入您的所有 Node ID，用空格隔开，然后按 Enter:"
    read -ra NODE_IDS
    if [ ${#NODE_IDS[@]} -eq 0 ]; then echo "未输入任何 Node ID，操作取消。"; return; fi
    printf "%s\n" "${NODE_IDS[@]}" > "$CONFIG_FILE"
    echo "已将 ${#NODE_IDS[@]} 个 Node ID 保存到配置中。"
    CPU_CORES=$(nproc)
    THREADS_PER_NODE=$((CPU_CORES / ${#NODE_IDS[@]}))
    if [ "$THREADS_PER_NODE" -eq 0 ]; then THREADS_PER_NODE=1; fi
    echo "检测到 $CPU_CORES 个CPU核心，将为每个节点分配 $THREADS_PER_NODE 个线程。"

    for i in "${!NODE_IDS[@]}"; do
        NODE_ID=${NODE_IDS[$i]}
        SESSION_NAME="nexus_node_$((i+1))"
        LOG_FILE="$PROJECT_ROOT_DIR/logs/${SESSION_NAME}.log"

        if tmux has-session -t "$SESSION_NAME" &> /dev/null; then
            tmux kill-session -t "$SESSION_NAME"; sleep 1
        fi

        echo "正在为 Node ID: $NODE_ID 启动节点 (会话: $SESSION_NAME)..."
        tmux new-session -d -s "$SESSION_NAME" \
            "$NODE_EXECUTABLE_PATH start --node-id $NODE_ID --max-threads $THREADS_PER_NODE > $LOG_FILE 2>&1"
    done

    echo "所有节点实例均已在后台启动！"
}

# (为了简洁，这里省略了其他函数的完整代码，它们保持之前的最终版本即可)
# ... stop_all_nodes, view_node_interface, show_current_config, uninstall_and_clean ...
# ... 主循环 ...
