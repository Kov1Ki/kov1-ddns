#!/usr/bin/env bash

# Cloudflare DDNS 安装脚本

# 严格的错误处理
set -o errexit     # 任何命令失败时立即退出。
set -o nounset     # 使用未定义变量时报错。
set -o pipefail    # 管道中任何命令失败时整个管道失败。

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色 - 重置为默认

# --- 配置路径 ---
INSTALL_DIR="/usr/local/bin"         # DDNS 脚本的安装目录
DDNS_SCRIPT_NAME="cf-ddns.sh"        # DDNS 脚本的文件名
DDNS_SCRIPT_PATH="$INSTALL_DIR/$DDNS_SCRIPT_NAME" # DDNS 脚本的完整路径
# GitHub 仓库的 Raw 文件基地址，用于下载 cf-ddns.sh
GITHUB_RAW_BASE="https://raw.githubusercontent.com/Kov1Ki/kov1-ddns/main"

# =====================================================================
# 函数
# =====================================================================

# 函数：记录安装过程中的消息
install_log() {
  local level="$1"
  local message="$2"
  local timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
  echo "[$timestamp] [$level] $message"
  # 你也可以将日志记录到文件中，例如：/var/log/kov1-ddns-install.log
  # echo "[$timestamp] [$level] $message" >> "/var/log/kov1-ddns-install.log"
}

# 函数：检查所需的安装依赖
check_install_dependencies() {
  install_log INFO "正在检查所需的安装依赖..."
  local dependencies=("curl" "jq" "crontab" "date") # 所需的命令列表
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &>/dev/null; then # 检查命令是否存在
      echo -e "${RED}❌ 错误: 找不到所需的命令 '${dep}'。${NC}" >&2
      echo -e "${RED}请安装它 (例如：sudo apt-get install $dep 或 sudo yum install $dep)。${NC}" >&2
      exit 1 # 缺少依赖时退出
    fi
  done
  install_log INFO "所有所需依赖已找到。"
}

# 函数：清理之前的安装遗留文件
clean_previous_install() {
  install_log INFO "正在检查之前的安装遗留文件..."
  if [ -f "$DDNS_SCRIPT_PATH" ]; then # 如果 DDNS 脚本已存在
    echo -e "${YELLOW}在 ${DDNS_SCRIPT_PATH} 找到之前的 DDNS 脚本。尝试卸载...${NC}"
    # 如果可能，调用现有脚本的卸载功能
    # 使用 bash -c 执行，确保其能在大多数环境中运行
    sudo bash -c "$DDNS_SCRIPT_PATH uninstall" || true # 允许卸载失败不中断安装
    install_log INFO "已尝试卸载之前的脚本。"
  fi

  # 如果卸载失败或脚本不存在，则删除残留文件
  if [ -d "/etc/cf-ddns" ]; then
    sudo rm -rf "/etc/cf-ddns" && install_log INFO "已删除 /etc/cf-ddns" || install_log WARN "删除 /etc/cf-ddns 失败"
  fi
  if [ -d "/var/lib/cf-ddns" ]; then
    sudo rm -rf "/var/lib/cf-ddns" && install_log INFO "已删除 /var/lib/cf-ddns" || install_log WARN "删除 /var/lib/cf-ddns 失败"
  fi
  if [ -f "/var/log/cf-ddns.log" ]; then
    sudo rm -f "/var/log/cf-ddns.log" && install_log INFO "已删除 /var/log/cf-ddns.log" || install_log WARN "删除 /var/log/cf-ddns.log 失败"
  fi
  install_log INFO "之前的安装清理完成。"
}

# 函数：执行实际的安装过程
perform_installation() {
  install_log INFO "正在启动 Cloudflare DDNS 安装..."
  echo -e "${CYAN}🚀 正在启动 Cloudflare DDNS 安装 🚀${NC}"

  # --- 下载 cf-ddns.sh 脚本 ---
  echo -e "${BLUE}正在从 GitHub 下载 ${DDNS_SCRIPT_NAME}...${NC}"
  # 将 cf-ddns.sh 下载到临时文件，然后复制
  local temp_ddns_script=$(mktemp)
  if ! curl -sL "${GITHUB_RAW_BASE}/${DDNS_SCRIPT_NAME}" -o "$temp_ddns_script"; then
    install_log ERROR "下载 ${DDNS_SCRIPT_NAME} 失败。"
    echo -e "${RED}❌ 错误: 下载 ${DDNS_SCRIPT_NAME} 失败。请检查网络或 GitHub 仓库。${NC}"
    rm -f "$temp_ddns_script" # 清理临时文件
    exit 1
  fi
  install_log SUCCESS "已成功下载 ${DDNS_SCRIPT_NAME}。"

  # --- 复制 cf-ddns.sh 脚本到安装目录 ---
  echo -e "${BLUE}正在将 DDNS 脚本复制到 ${INSTALL_DIR}...${NC}"
  if ! sudo cp "$temp_ddns_script" "$DDNS_SCRIPT_PATH"; then
    install_log ERROR "复制 ${DDNS_SCRIPT_NAME} 到 ${INSTALL_DIR} 失败。"
    echo -e "${RED}❌ 错误: 复制 ${DDNS_SCRIPT_NAME} 到 ${INSTALL_DIR} 失败。${NC}"
    rm -f "$temp_ddns_script" # 清理临时文件
    exit 1
  fi
  install_log SUCCESS "已将 ${DDNS_SCRIPT_NAME} 复制到 ${DDNS_SCRIPT_PATH}。"
  rm -f "$temp_ddns_script" # 删除临时下载文件

  # --- 设置执行权限 ---
  echo -e "${BLUE}正在设置执行权限...${NC}"
  if ! sudo chmod +x "$DDNS_SCRIPT_PATH"; then
    install_log ERROR "为 ${DDNS_SCRIPT_PATH} 设置执行权限失败。"
    echo -e "${RED}❌ 错误: 为 ${DDNS_SCRIPT_PATH} 设置执行权限失败。${NC}"
    exit 1
  fi
  install_log SUCCESS "已为 ${DDNS_SCRIPT_PATH} 设置执行权限。"

  # --- 运行 DDNS 脚本的安装命令 ---
  echo -e "${BLUE}正在运行 DDNS 脚本的交互式安装...${NC}"
  # 这将调用 cf-ddns.sh 内部的 install_ddns 函数
  if ! sudo "$DDNS_SCRIPT_PATH" install; then
    install_log ERROR "DDNS 脚本交互式安装失败。"
    echo -e "${RED}❌ 错误: DDNS 脚本交互式安装失败。${NC}"
    echo -e "${RED}请查看日志或再次尝试运行 'sudo ${DDNS_SCRIPT_PATH}'。${NC}"
    exit 1
  fi
  install_log SUCCESS "DDNS 脚本交互式安装完成。"

  echo -e "${GREEN}🎉 Cloudflare DDNS 已成功安装和配置！${NC}"
  echo -e "${GREEN}您可以通过运行 '${BLUE}sudo $DDNS_SCRIPT_PATH${NC}' 来管理它。${NC}"
  install_log SUCCESS "安装成功完成。"
}

# =====================================================================
# 主程序执行
# =====================================================================

# 确保脚本以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}❌ 错误: 此脚本必须以 root 权限运行。请使用 'sudo'。${NC}" >&2
  exit 1
fi

check_install_dependencies   # 检查依赖项
clean_previous_install       # 清理旧安装
perform_installation         # 执行安装过程

exit 0
