#!/usr/bin/env bash
# Cloudflare DDNS 管理脚本

# 严格的错误处理：
set -o errexit  # 任何命令失败时立即退出。
set -o nounset  # 使用未定义变量时报错。
set -o pipefail # 管道中任何命令失败时整个管道失败。

# 设置时区以便日志时间一致。
export TZ="Asia/Shanghai"

# --- 配置路径 ---
CONFIG_DIR="/etc/cf-ddns"
DATA_DIR="/var/lib/cf-ddns"
CONFIG_FILE="$CONFIG_DIR/config.conf"
LOG_FILE="/var/log/cf-ddns.log"
# 新增：记录上次日志删除日期的文件
LAST_ROTATED_DATE_FILE="$DATA_DIR/.last_log_rotated_date"
CRON_JOB_ID="CLOUDFLARE_DDNS_JOB" # 定时任务的唯一标识符

# --- 默认配置参数 (将被配置文件覆盖) ---
CFKEY=""               # Cloudflare API 密钥
CFUSER=""              # Cloudflare 账户邮箱
CFZONE_NAME=""         # 域名区域 (例如：example.com)
CFRECORD_NAME=""       # 完整记录名称 (例如：host.example.com)
CFRECORD_TYPE="BOTH"   # 记录类型：A (IPv4) | AAAA (IPv6) | BOTH (双栈)
CFTTL=120              # DNS 记录 TTL 值 (120-86400 秒)
FORCE=false            # 强制更新模式 (忽略本地 IP 缓存)
TG_BOT_TOKEN=""        # Telegram 机器人 Token
TG_CHAT_ID=""          # Telegram 聊天 ID

# --- 公网 IP 检测服务 (多源冗余) ---
# 优先使用 HTTPS 以提高安全性，如果 curl 支持。
# 检查常用公网 IP 端点。
declare -a WANIPSITE_v4=(
  "https://ipv4.icanhazip.com"
  "https://api.ipify.org"
  "https://ident.me"
)
declare -a WANIPSITE_v6=(
  "https://ipv6.icanhazip.com"
  "https://v6.ident.me"
  "https://api6.ipify.org"
)

# --- 终端颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色 - 重置为默认

# =====================================================================
# 实用函数
# =====================================================================

# 函数：记录消息到文件并输出到标准错误
log_message() {
  local level="$1" # INFO, WARN, ERROR, SUCCESS
  local message="$2"
  local timestamp="$(date +"%Y-%m-%d %H:%M:%S %Z")"
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
  
  # 根据级别设置终端输出颜色
  local level_color="${NC}"
  case "$level" in
    "INFO") level_color="${BLUE}" ;;
    "WARN") level_color="${YELLOW}" ;;
    "ERROR") level_color="${RED}" ;;
    "SUCCESS") level_color="${GREEN}" ;;
  esac
  echo -e "${level_color}$(date +"%H:%M:%S") [$level] $message${NC}" >&2 # 输出到标准错误以便在终端中可见
}

# 函数：显示主菜单
show_main_menu() {
  clear
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${BLUE}        🚀 CloudFlare DDNS 管理脚本 🚀     ${NC}"
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${GREEN} 1. ✨ 安装并配置 DDNS${NC}"
  echo -e "${GREEN} 2. ⚙️ 修改 DDNS 配置${NC}"
  echo -e "${GREEN} 3. 🗑️ 卸载 DDNS${NC}"
  echo -e "${GREEN} 4. 📋 查看当前配置${NC}"
  echo -e "${GREEN} 5. ⚡ 手动运行更新${NC}"
  echo -e "${GREEN} 6. 📜 查看日志${NC}"
  echo -e "${GREEN} 7. 💬 配置 Telegram 通知${NC}"
  echo -e "${GREEN} 8. 🚪 退出脚本${NC}"
  echo -e "${CYAN}==============================================${NC}"
  echo
  read -p "$(echo -e "${PURPLE}请选择一个操作 [1-8]: ${NC}")" main_choice
}

# 函数：初始化目录结构
init_dirs() {
  log_message INFO "正在初始化目录..."
  local dirs=("$CONFIG_DIR" "$DATA_DIR")
  for dir in "${dirs[@]}"; do
    if [ ! -d "$dir" ]; then
      log_message INFO "正在创建目录: $dir"
      echo -e "${BLUE}创建目录: ${dir}${NC}"
      if ! mkdir -p "$dir"; then
        log_message ERROR "创建目录失败: $dir"
        echo -e "${RED}错误: 创建目录失败: ${dir}${NC}"
        exit 1
      fi
      if ! chmod 700 "$dir"; then
        log_message ERROR "设置目录权限失败: $dir"
        echo -e "${RED}错误: 设置目录权限失败: ${dir}${NC}"
        exit 1
      fi
    fi
  done
  
  # 确保日志文件存在并设置权限
  if [ ! -f "$LOG_FILE" ]; then
    log_message INFO "正在创建日志文件: $LOG_FILE"
    echo -e "${BLUE}创建日志文件: ${LOG_FILE}${NC}"
    if ! touch "$LOG_FILE"; then
      log_message ERROR "创建日志文件失败: $LOG_FILE"
      echo -e "${RED}错误: 创建日志文件失败: ${LOG_FILE}${NC}"
      exit 1
    fi
    # 设置日志文件权限，例如：rw-r----- (640)，以便 root 读写，其他用户只读
    if ! chmod 640 "$LOG_FILE"; then
      log_message ERROR "设置日志文件权限失败: $LOG_FILE"
      echo -e "${RED}错误: 设置日志文件权限失败: ${LOG_FILE}${NC}"
      exit 1
    fi
  fi

  # 确保记录上次轮换日期的文件存在
  if [ ! -f "$LAST_ROTATED_DATE_FILE" ]; then
    log_message INFO "正在创建上次轮换日期文件: $LAST_ROTATED_DATE_FILE"
    if ! touch "$LAST_ROTATED_DATE_FILE"; then
      log_message ERROR "创建上次轮换日期文件失败: $LAST_ROTATED_DATE_FILE"
      echo -e "${RED}错误: 创建上次轮换日期文件失败: ${LAST_ROTATED_DATE_FILE}${NC}"
      exit 1
    fi
    # 初始写入当前日期，确保第一次运行时不立即删除
    date +"%Y-%m-%d" > "$LAST_ROTATED_DATE_FILE"
    if ! chmod 600 "$LAST_ROTATED_DATE_FILE"; then
      log_message ERROR "设置上次轮换日期文件权限失败: $LAST_ROTATED_DATE_FILE"
      echo -e "${RED}错误: 设置上次轮换日期文件权限失败: ${LAST_ROTATED_DATE_FILE}${NC}"
      exit 1
    fi
  fi

  log_message INFO "目录初始化完成。"
  echo -e "${GREEN}目录初始化完成!${NC}"
}

# 函数：日志轮换（每周一次）
rotate_logs() {
  log_message INFO "正在检查是否需要日志轮换..."

  local current_date_seconds=$(date +%s) # 当前日期秒数
  local last_rotated_date_str=""

  if [ -f "$LAST_ROTATED_DATE_FILE" ]; then
    last_rotated_date_str=$(cat "$LAST_ROTATED_DATE_FILE" | head -n 1)
  fi

  # 如果文件不存在或内容为空，则认为是第一次运行，记录当前日期并跳过删除
  if [ -z "$last_rotated_date_str" ]; then
    log_message INFO "首次运行或上次轮换日期文件为空，记录当前日期。"
    date +"%Y-%m-%d" > "$LAST_ROTATED_DATE_FILE"
    return # 不进行删除
  fi

  local last_rotated_date_seconds=$(date -d "$last_rotated_date_str" +%s 2>/dev/null)

  # 检查 date -d 命令是否成功，如果失败则重新初始化
  if [ $? -ne 0 ]; then
    log_message WARN "无法解析上次轮换日期 '$last_rotated_date_str'，重新初始化。"
    date +"%Y-%m-%d" > "$LAST_ROTATED_DATE_FILE"
    return # 不进行删除
  fi

  # 计算自上次删除以来的天数
  local days_since_last_rotation=$(( (current_date_seconds - last_rotated_date_seconds) / 86400 )) # 86400 秒 = 1 天

  local min_days_for_rotation=7 # 每周删除一次，即 >= 7 天

  if [ "$days_since_last_rotation" -ge "$min_days_for_rotation" ]; then
    log_message INFO "上次日志删除日期是 $last_rotated_date_str (${days_since_last_rotation} 天前)。满足轮换条件。"
    echo -e "${YELLOW}日志文件已达到轮换条件 (${days_since_last_rotation} 天)。正在删除旧日志...${NC}"

    if [ -f "$LOG_FILE" ]; then
      log_message INFO "正在删除旧日志文件: $LOG_FILE"
      if ! rm "$LOG_FILE"; then
        log_message ERROR "删除旧日志文件失败: $LOG_FILE"
        echo -e "${RED}错误: 删除旧日志文件失败: ${LOG_FILE}${NC}"
        return
      fi
      log_message SUCCESS "旧日志文件已成功删除。"
    else
      log_message INFO "日志文件 $LOG_FILE 不存在，无需删除。"
    fi

    # 删除后，重新创建日志文件并更新上次轮换日期
    if ! touch "$LOG_FILE"; then
      log_message ERROR "重新创建日志文件失败: $LOG_FILE"
      echo -e "${RED}错误: 重新创建日志文件失败: ${LOG_FILE}${NC}"
      return
    fi
    if ! chmod 640 "$LOG_FILE"; then
      log_message ERROR "设置新日志文件权限失败: $LOG_FILE"
      echo -e "${RED}错误: 设置新日志文件权限失败: ${LOG_FILE}${NC}"
      return
    fi
    
    # 更新上次轮换日期到当前日期
    date +"%Y-%m-%d" > "$LAST_ROTATED_DATE_FILE"
    log_message SUCCESS "日志已轮换。新的日志文件已创建，上次轮换日期已更新到今天。"
    echo -e "${GREEN}✅ 日志轮换完成。${NC}"
  else
    log_message INFO "日志轮换条件不满足。上次删除是 $last_rotated_date_str，距今 ${days_since_last_rotation} 天。"
    echo -e "${BLUE}日志轮换条件不满足 (${days_since_last_rotation} 天)。无需删除。${NC}"
  fi
}


# =====================================================================
# 配置函数
# =====================================================================

# (interactive_config, configure_telegram, save_config, load_config 函数保持不变)

# 函数：添加定时任务
add_cron_job() {
  local script_path="$(realpath "$0")"
  
  log_message INFO "正在检查 $script_path 的现有定时任务..."
  echo -e "${BLUE}正在检查现有定时任务...${NC}"
  # 通过 ID 或脚本路径检查定时任务是否已存在
  if crontab -l 2>/dev/null | grep -q "$CRON_JOB_ID"; then
    log_message INFO "找到现有定时任务，正在更新..."
    echo -e "${YELLOW}发现现有定时任务，正在尝试更新...${NC}"
    remove_cron_job
  fi
  
  # 定义定时任务调度和命令
  local cron_schedule="*/2 * * * *" # 每 2 分钟
  local cron_command="$cron_schedule $script_path update >> '$LOG_FILE' 2>&1 # $CRON_JOB_ID"
  
  # 添加定时任务
  (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
  
  if [ $? -eq 0 ]; then
    log_message SUCCESS "定时任务已添加: '$cron_schedule $script_path update'。"
    echo -e "${GREEN}✅ 定时任务已成功添加: 每 2 分钟运行一次。${NC}"
    echo -e "   日志文件: ${BLUE}$LOG_FILE${NC}"
  else
    log_message ERROR "添加定时任务失败。"
    echo -e "${RED}❌ 错误: 添加定时任务失败。请检查您的 crontab 设置。${NC}"
    exit 1
  fi
}

# (remove_cron_job, uninstall_ddns 函数保持不变)

# =====================================================================
# 核心 DDNS 逻辑函数
# =====================================================================

# (send_tg_notification, get_wan_ip, update_record, process_record_type 函数保持不变)

# =====================================================================
# 函数：执行 DDNS 更新
# =====================================================================
run_ddns_update() {
  # 放在这里，确保每次 DDNS 更新时都会检查日志轮换
  rotate_logs 
  
  log_message INFO "正在启动动态 DNS 更新过程。"
  echo -e "${BLUE}⚡ 正在启动动态 DNS 更新...${NC}"
  
  # 加载配置
  if ! load_config; then
    log_message ERROR "找不到配置文件或配置不完整。无法运行 DDNS 更新。"
    # 优化后的配置文件错误通知
    local message="❌ *Cloudflare DDNS 错误* ❌

*配置文件缺失或不完整!*
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请运行安装程序或修改配置。"
    send_tg_notification "$message"
    echo -e "${RED}❌ 错误: 配置文件缺失或不完整。请先安装或修改配置。${NC}"
    exit 1
  fi
  
  # 基本配置验证
  if [[ -z "$CFKEY" || -z "$CFUSER" || -z "$CFZONE_NAME" || -z "$CFRECORD_NAME" ]]; then
    log_message ERROR "缺少必要的 Cloudflare 配置参数。无法继续。"
    # 优化后的配置参数缺失通知
    local message="❌ *Cloudflare DDNS 错误* ❌

*缺少必要的 Cloudflare 配置参数!*
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请运行安装程序或修改配置。"
    send_tg_notification "$message"
    echo -e "${RED}❌ 错误: 缺少必要的 Cloudflare 配置参数。无法继续。${NC}"
    exit 1
  fi
  
  local update_status_v4=0
  local update_status_v6=0

  # 根据 CFRECORD_TYPE 处理更新
  case "$CFRECORD_TYPE" in
    "A")
      process_record_type "A" || update_status_v4=1
      ;;
    "AAAA")
      process_record_type "AAAA" || update_status_v6=1
      ;;
    "BOTH")
      process_record_type "A" || update_status_v4=1
      process_record_type "AAAA" || update_status_v6=1
      ;;
    *)
      log_message ERROR "配置的记录类型无效: '$CFRECORD_TYPE'。必须是 A、AAAA 或 BOTH。"
      echo -e "${RED}❌ 错误: 配置的记录类型无效: '${CFRECORD_TYPE}'。必须是 A、AAAA 或 BOTH。${NC}"
      exit 2
      ;;
  esac
  
  if [ "$update_status_v4" -eq 0 ] && [ "$update_status_v6" -eq 0 ]; then
    log_message SUCCESS "动态 DNS 更新过程完成成功。"
    echo -e "${GREEN}✅ 动态 DNS 更新过程成功完成。${NC}"
  else
    log_message ERROR "动态 DNS 更新过程完成但有错误。"
    echo -e "${RED}❌ 动态 DNS 更新过程完成但有错误。请查看日志。${NC}"
  fi
}

# (install_ddns, modify_config, show_current_config, view_logs 函数保持不变)


# =====================================================================
# 主程序入口
# =====================================================================

# 确保必要的工具可用
check_dependencies() {
  local dependencies=("curl" "grep" "sed" "jq") # 添加了 jq 用于健壮的 JSON 解析
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      echo -e "${RED}❌ 错误: 找不到所需的命令 '${dep}'。${NC}" >&2
      echo -e "${RED}请安装它 (例如：sudo apt-get install $dep 或 sudo yum install $dep)。${NC}" >&2
      exit 1
    fi
  done
}

# 初始检查
check_dependencies
init_dirs # 确保在任何日志记录发生之前目录和日志文件存在

# 检查是否以 root 运行
if [ "$(id -u)" -ne 0 ]; then
  log_message ERROR "此脚本需要 root 权限运行。"
  echo -e "${RED}❌ 错误: 此脚本需要 root 权限运行。请使用 'sudo' 执行。${NC}"
  exit 1
fi

# 处理命令行参数
if [ $# -gt 0 ]; then
  case "$1" in
    update)
      log_message INFO "命令行参数: update"
      run_ddns_update
      exit 0
      ;;
    install)
      log_message INFO "命令行参数: install"
      install_ddns
      exit 0
      ;;
    modify)
      log_message INFO "命令行参数: modify"
      modify_config
      exit 0
      ;;
    uninstall)
      log_message INFO "命令行参数: uninstall"
      uninstall_ddns
      exit 0
      ;;\
    *)\
      log_message ERROR "无效的命令行参数: $1"
      echo -e "${RED}❌ 无效参数: ${1}${NC}"
      echo -e "${YELLOW}用法: ${NC}$(basename "$0") ${GREEN}[update|install|modify|uninstall]${NC}"
      exit 1
      ;;
  esac
fi

# 如果没有参数，则显示主菜单
while true; do
  show_main_menu
  
  case $main_choice in
    1)
      install_ddns
      ;;
    2)
      modify_config
      ;;
    3)
      uninstall_ddns
      ;;
    4)
      show_current_config
      ;;
    5)
      echo -e "${YELLOW}⚡ 正在手动运行更新...${NC}"
      log_message INFO "从菜单手动触发更新。"
      run_ddns_update
      echo -e "${GREEN}🎉 更新完成! 请查看日志以获取详细信息。${NC}"
      read -p "按回车键返回主菜单..."
      ;;
    6)
      view_logs
      ;;
    7)
      configure_telegram
      ;;  
    8)
      log_message INFO "从菜单退出脚本。"
      echo -e "${GREEN}👋 退出脚本。再见!${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}❌ 无效选项，请重新输入。${NC}"
      sleep 2
      ;;
  esac
done