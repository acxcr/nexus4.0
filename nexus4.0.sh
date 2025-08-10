#!/bin/bash

# 定义项目目录和配置文件路径
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$SCRIPT_DIR/nexus-node"
CONFIG_FILE="$PROJECT_ROOT_DIR/data/node_configs.conf"

# 函数：检查并安装依赖
function check_and_install_dependencies() {
    echo "检查并安装依赖..."
    if ! command -v cargo &> /dev/null; then
        echo "Rust 和 Cargo 未安装，正在安装..."
        curl https://sh.rustup.rs -sSf | sh -s -- -y
        source "$HOME/.cargo/env"
        echo "Rust 和 Cargo 安装完成 。"
    else
        echo "Rust 和 Cargo 已安装。"
    fi
    if ! command -v make &> /dev/null || ! command -v gcc &> /dev/null; then
        echo "构建工具未安装，正在安装..."
        sudo apt-get update
        sudo apt-get install -y build-essential pkg-config libssl-dev clang cmake
        echo "构建工具安装完成。"
    else
        echo "构建工具已安装。"
    fi
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
    echo "========== Nexus 多节点管理 =========="
    echo "1. 安装/更新并启动所有节点"
    echo "2. 停止并删除所有节点"
    echo "3. 查看节点日志"
    echo "4. 查看已保存的节点配置"
    echo "5. 退出"
    echo "========================================"
}

# 函数：安装/更新并启动节点
function install_and_start_node() {
    echo "正在安装/更新节点程序..."
    check_and_install_dependencies

    if [ -d "$PROJECT_ROOT_DIR/nexus-cli" ]; then
        echo "检测到现有仓库，正在更新..."
        cd "$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
        git pull
    else
        echo "克隆 Nexus CLI 仓库..."
        mkdir -p "$PROJECT_ROOT_DIR"
        cd "$PROJECT_ROOT_DIR"
        git clone https://github.com/nexus-xyz/nexus-cli.git
        mkdir -p "$PROJECT_ROOT_DIR/data"
        mkdir -p "$PROJECT_ROOT_DIR/logs"
        cd "$PROJECT_ROOT_DIR/nexus-cli/clients/cli"
    fi

    echo "编译 Nexus CLI..."
    cargo build --release

    echo "请输入您的所有 Node ID ，用空格隔开，然后按 Enter:"
    read -ra NODE_IDS
    if [ ${#NODE_IDS[@]} -eq 0 ]; then
        echo "未输入任何 Node ID，操作取消。"
        return
    fi

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
            echo "正在停止旧的会话 $SESSION_NAME..."
            tmux kill-session -t "$SESSION_NAME"
            sleep 1
        fi

        echo "正在为 Node ID: $NODE_ID 启动节点 (会话: $SESSION_NAME)..."
        tmux new-session -d -s "$SESSION_NAME" \
            "$PROJECT_ROOT_DIR/nexus-cli/clients/cli/target/release/nexus-network start --node-id $NODE_ID --max-threads $THREADS_PER_NODE > $LOG_FILE 2>&1"
    done

    echo "所有节点实例均已在后台启动！"
}

# 函数：停止并删除节点
function stop_and_delete_node() {
    echo "正在停止所有 nexus_node_* 会话..."
    tmux ls | grep "nexus_node_" | cut -d: -f1 | xargs -r -I{} tmux kill-session -t {}
    echo "所有节点会话已停止。"

    if [ -d "$PROJECT_ROOT_DIR" ]; then
        read -rp "确定要删除整个项目目录 ($PROJECT_ROOT_DIR) 吗？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            echo "正在删除项目目录..."
            rm -rf "$PROJECT_ROOT_DIR"
            echo "项目目录已删除。"
        else
            echo "删除操作已取消。"
        fi
    fi
}

# 函数：查看节点日志 (按照您的仪表盘设计重构)
function view_node_logs() {
    # 检查配置文件是否存在，以便读取Node ID
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误：未找到配置文件 $CONFIG_FILE。"
        echo "请先运行一次选项1来生成配置。"
        return
    fi
    # 将配置文件中的Node ID读入数组
    mapfile -t SAVED_IDS < "$CONFIG_FILE"

    # 打印抬头，使用 printf 进行格式化对齐
    printf "%-10s %-15s %-10s %-20s\n" "组" "节点ID" "状态" "已运行时间"
    echo "==============================================================="

    # 检查是否有任何正在运行的节点
    if ! tmux ls | grep -q "nexus_node_"; then
        echo "没有检测到正在运行的节点。"
        return
    fi

    # 循环遍历已保存的ID，并检查每个ID对应的tmux会话状态
    for i in "${!SAVED_IDS[@]}"; do
        GROUP_NUM=$((i+1))
        NODE_ID=${SAVED_IDS[$i]}
        SESSION_NAME="nexus_node_$GROUP_NUM"

        if tmux has-session -t "$SESSION_NAME" &> /dev/null; then
            STATUS="✅ 运行中"
            # 获取tmux会话的创建时间戳
            CREATION_TIMESTAMP=$(tmux display-message -p -t "$SESSION_NAME" '#{session_created}')
            # 获取当前时间戳
            NOW_TIMESTAMP=$(date +%s)
            # 计算运行时间（秒）
            UPTIME_SECONDS=$((NOW_TIMESTAMP - CREATION_TIMESTAMP))
            # 格式化运行时间为 天-时-分-秒
            UPTIME_FORMATTED=$(printf '%dd-%dh-%dm-%ds' $((UPTIME_SECONDS/86400)) $((UPTIME_SECONDS%86400/3600)) $((UPTIME_SECONDS%3600/60)) $((UPTIME_SECONDS%60)))
        else
            STATUS="❌ 已停止"
            UPTIME_FORMATTED="N/A"
        fi
        # 打印格式化后的一行信息
        printf "%-10s %-15s %-10s %-20s\n" "组 $GROUP_NUM" "$NODE_ID" "$STATUS" "$UPTIME_FORMATTED"
    done

    echo "==============================================================="
    read -rp "请输入您想查看日志的组数字 (例如: 1): " choice
    
    # 验证输入是否为数字
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "错误：请输入一个有效的数字。"
        return
    fi

    LOG_FILE="$PROJECT_ROOT_DIR/logs/nexus_node_${choice}.log"
    
    if [ -f "$LOG_FILE" ]; then
        echo "显示日志: $LOG_FILE (按 Ctrl+C 退出)"
        # 使用 tail -f 实时跟踪日志文件
        tail -f "$LOG_FILE"
    else
        echo "错误：找不到日志文件 $LOG_FILE。可能该组的节点从未成功启动过。"
    fi
}

# 函数：显示当前配置
function show_current_config() {
    echo "--- 已保存的 Node ID 列表 ---"
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
        echo "-----------------------------"
    else
        echo "未找到配置文件。请先运行选项1来设置。"
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
