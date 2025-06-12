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

# 函数：交互式配置 DDNS
interactive_config() {
  log_message INFO "正在进入交互式配置模式..."
  echo -e "${CYAN}--- DDNS 配置 ---${NC}"
  
  # 加载现有配置
  load_config || true # 如果文件不存在也不报错

  read -rp "$(echo -e "${PURPLE}请输入您的 Cloudflare API 密钥 (Global API Key): ${NC}[${CFKEY:-未设置}] ")" input
  [ -n "$input" ] && CFKEY="$input"

  read -rp "$(echo -e "${PURPLE}请输入您的 Cloudflare 账户邮箱: ${NC}[${CFUSER:-未设置}] ")" input
  [ -n "$input" ] && CFUSER="$input"

  read -rp "$(echo -e "${PURPLE}请输入您的域名区域 (例如: example.com): ${NC}[${CFZONE_NAME:-未设置}] ")" input
  [ -n "$input" ] && CFZONE_NAME="$input"

  read -rp "$(echo -e "${PURPLE}请输入您的完整记录名称 (例如: host.example.com): ${NC}[${CFRECORD_NAME:-未设置}] ")" input
  [ -n "$input" ] && CFRECORD_NAME="$input"
  
  # 选择记录类型
  while true; do
    echo -e "${PURPLE}请选择要更新的记录类型:${NC}"
    echo -e "  ${GREEN}1) A (IPv4 only)${NC}"
    echo -e "  ${GREEN}2) AAAA (IPv6 only)${NC}"
    echo -e "  ${GREEN}3) BOTH (双栈)${NC}"
    read -rp "$(echo -e "${PURPLE}选择 [1-3]: ${NC}[${CFRECORD_TYPE:-BOTH}] ")" input_type
    case "$input_type" in
      1) CFRECORD_TYPE="A"; break ;;
      2) CFRECORD_TYPE="AAAA"; break ;;
      3) CFRECORD_TYPE="BOTH"; break ;;
      "") break ;; # 如果为空，保持默认值
      *) echo -e "${RED}无效选项，请重新输入。${NC}" ;;
    esac
  done

  # TTL
  read -rp "$(echo -e "${PURPLE}请输入 TTL (120-86400秒): ${NC}[${CFTTL:-120}] ")" input_ttl
  if [ -n "$input_ttl" ]; then
    if [[ "$input_ttl" =~ ^[0-9]+$ ]] && (( input_ttl >= 120 && input_ttl <= 86400 )); then
      CFTTL="$input_ttl"
    else
      echo -e "${YELLOW}警告: TTL 值无效或超出范围，将使用默认值 120。${NC}"
      CFTTL=120
    fi
  fi

  # 强制更新模式
  while true; do
    read -rp "$(echo -e "${PURPLE}是否强制更新模式 (忽略本地 IP 缓存，每次都更新)？ (y/n): ${NC}[${FORCE:-false}] ")" input_force
    case "$input_force" in
      [yY]|[yY][eE][sS]) FORCE=true; break ;;
      [nN]|[nN][oO]) FORCE=false; break ;;
      "") break ;;
      *) echo -e "${RED}无效选项，请重新输入。${NC}" ;;
    esac
  done

  save_config # 保存配置
  log_message INFO "交互式配置完成。"
  echo -e "${GREEN}配置已保存。${NC}"
  sleep 1
}

# 函数：配置 Telegram 通知
configure_telegram() {
  log_message INFO "正在进入 Telegram 配置模式..."
  echo -e "${CYAN}--- Telegram 通知配置 ---${NC}"
  echo -e "${YELLOW}提示: 您可以访问 https://t.me/BotFather 创建机器人并获取 Token，${NC}"
  echo -e "${YELLOW}然后向您的机器人发送任意消息以获取 Chat ID。${NC}"
  echo -e "${YELLOW}您可以通过访问 https://api.telegram.org/bot<您的BOT_TOKEN>/getUpdates 获取 Chat ID。${NC}"
  
  load_config || true # 如果文件不存在也不报错

  read -rp "$(echo -e "${PURPLE}请输入您的 Telegram Bot Token (留空则禁用): ${NC}[${TG_BOT_TOKEN:-未设置}] ")" input
  TG_BOT_TOKEN="$input" # 允许设置为空以禁用

  read -rp "$(echo -e "${PURPLE}请输入您的 Telegram Chat ID (留空则禁用): ${NC}[${TG_CHAT_ID:-未设置}] ")" input
  TG_CHAT_ID="$input" # 允许设置为空以禁用

  save_config # 保存配置
  log_message INFO "Telegram 配置完成。"
  echo -e "${GREEN}Telegram 配置已保存。${NC}"
  sleep 1
}

# 函数：保存配置
save_config() {
  log_message INFO "正在保存配置到 $CONFIG_FILE..."
  {
    echo "# Cloudflare DDNS 配置"
    echo "CFKEY=\"$CFKEY\""
    echo "CFUSER=\"$CFUSER\""
    echo "CFZONE_NAME=\"$CFZONE_NAME\""
    echo "CFRECORD_NAME=\"$CFRECORD_NAME\""
    echo "CFRECORD_TYPE=\"$CFRECORD_TYPE\""
    echo "CFTTL=$CFTTL"
    echo "FORCE=$FORCE"
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\""
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\""
  } > "$CONFIG_FILE"

  if [ $? -eq 0 ]; then
    log_message SUCCESS "配置已成功保存。"
    echo -e "${GREEN}配置已成功保存到 ${CONFIG_FILE}${NC}"
  else
    log_message ERROR "保存配置失败。"
    echo -e "${RED}错误: 保存配置失败到 ${CONFIG_FILE}${NC}"
    exit 1
  fi
}

# 函数：加载配置
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    log_message INFO "正在从 $CONFIG_FILE 加载配置..."
    # 使用 set -a 将变量导出，以便在脚本的其余部分可用
    set -a
    . "$CONFIG_FILE" # 源 (source) 配置文件
    set +a
    log_message INFO "配置加载完成。"
    return 0 # 成功加载
  else
    log_message WARN "配置文件 $CONFIG_FILE 不存在。"
    return 1 # 文件不存在
  fi
}

# 函数：安装并配置 DDNS
install_ddns() {
  log_message INFO "正在启动安装向导..."
  echo -e "${CYAN}🚀 欢迎使用 CloudFlare DDNS 安装向导 🚀${NC}"
  echo -e "${YELLOW}此向导将帮助您配置 DDNS 服务并设置定时任务。${NC}"
  
  init_dirs # 确保目录存在
  interactive_config # 交互式配置
  add_cron_job # 添加定时任务
  
  log_message SUCCESS "DDNS 安装和配置完成。"
  echo -e "${GREEN}✅ CloudFlare DDNS 已成功安装并配置。${NC}"
  echo -e "${BLUE}您可以随时通过运行此脚本并选择菜单选项来修改配置。${NC}"
  read -p "按回车键返回主菜单..."
}

# 函数：修改 DDNS 配置
modify_config() {
  log_message INFO "正在启动修改配置向导..."
  echo -e "${CYAN}⚙️ 修改 CloudFlare DDNS 配置 ⚙️${NC}"
  
  init_dirs # 确保目录存在
  interactive_config # 交互式配置
  
  log_message SUCCESS "DDNS 配置修改完成。"
  echo -e "${GREEN}✅ CloudFlare DDNS 配置已成功修改。${NC}"
  read -p "按回车键返回主菜单..."
}

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

# 函数：删除定时任务
remove_cron_job() {
  log_message INFO "正在删除现有定时任务..."
  echo -e "${YELLOW}正在删除现有定时任务...${NC}"
  local temp_cron_file=$(mktemp)
  crontab -l 2>/dev/null | grep -v "$CRON_JOB_ID" > "$temp_cron_file"
  crontab "$temp_cron_file"
  rm "$temp_cron_file"
  if [ $? -eq 0 ]; then
    log_message SUCCESS "现有定时任务已成功删除。"
    echo -e "${GREEN}✅ 现有定时任务已删除。${NC}"
  else
    log_message ERROR "删除现有定时任务失败。"
    echo -e "${RED}❌ 错误: 删除现有定时任务失败。${NC}"
  fi
}

# 函数：卸载 DDNS
uninstall_ddns() {
  log_message INFO "正在启动卸载向导..."
  echo -e "${RED}🗑️ 卸载 CloudFlare DDNS 🗑️${NC}"
  read -rp "$(echo -e "${YELLOW}您确定要卸载 DDNS 服务吗？这将删除所有配置、日志和定时任务。(y/n): ${NC}")" confirm_uninstall

  if [[ "$confirm_uninstall" =~ ^[yY]$ ]]; then
    remove_cron_job

    log_message INFO "正在删除配置目录: $CONFIG_DIR"
    if [ -d "$CONFIG_DIR" ]; then
      if ! rm -rf "$CONFIG_DIR"; then
        log_message ERROR "删除配置目录失败: $CONFIG_DIR"
        echo -e "${RED}错误: 删除配置目录失败: ${CONFIG_DIR}${NC}"
      else
        log_message SUCCESS "配置目录已删除。"
        echo -e "${GREEN}✅ 配置目录已删除: ${CONFIG_DIR}${NC}"
      fi
    fi

    log_message INFO "正在删除数据目录: $DATA_DIR"
    if [ -d "$DATA_DIR" ]; then
      if ! rm -rf "$DATA_DIR"; then
        log_message ERROR "删除数据目录失败: $DATA_DIR"
        echo -e "${RED}错误: 删除数据目录失败: ${DATA_DIR}${NC}"
      else
        log_message SUCCESS "数据目录已删除。"
        echo -e "${GREEN}✅ 数据目录已删除: ${DATA_DIR}${NC}"
      fi
    fi

    log_message INFO "正在删除日志文件: $LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
      if ! rm "$LOG_FILE"; then
        log_message ERROR "删除日志文件失败: $LOG_FILE"
        echo -e "${RED}错误: 删除日志文件失败: ${LOG_FILE}${NC}"
      else
        log_message SUCCESS "日志文件已删除。"
        echo -e "${GREEN}✅ 日志文件已删除: ${LOG_FILE}${NC}"
      fi
    fi
    
    log_message SUCCESS "CloudFlare DDNS 卸载完成。"
    echo -e "${GREEN}✅ CloudFlare DDNS 已成功卸载。${NC}"
  else
    log_message INFO "用户取消了卸载。"
    echo -e "${YELLOW}卸载已取消。${NC}"
  fi
  read -p "按回车键返回主菜单..."
}

# =====================================================================
# 核心 DDNS 逻辑函数
# =====================================================================

# 函数：发送 Telegram 通知
send_tg_notification() {
  local message="$1"
  if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    log_message INFO "正在发送 Telegram 通知..."
    curl -s -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"chat_id\": \"$TG_CHAT_ID\", \"text\": \"$message\", \"parse_mode\": \"Markdown\"}" \
      "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      log_message INFO "Telegram 通知发送成功。"
    else
      log_message ERROR "Telegram 通知发送失败。"
    fi
  fi
}

# 函数：获取公网 IPv4 地址
get_wan_ip_v4() {
  log_message INFO "正在尝试获取 IPv4 地址..."
  for site in "${WANIPSITE_v4[@]}"; do
    local ip=$(curl -s -4 "$site" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    if [[ -n "$ip" && "$ip" != "0.0.0.0" ]]; then
      log_message INFO "通过 $site 获取到 IPv4 地址: $ip"
      echo "$ip"
      return 0
    fi
  done
  log_message ERROR "未能获取到 IPv4 地址。"
  return 1
}

# 函数：获取公网 IPv6 地址
get_wan_ip_v6() {
  log_message INFO "正在尝试获取 IPv6 地址..."
  # 确保系统支持 IPv6 且有 IPv6 路由
  if ! ip -6 route show default > /dev/null 2>&1; then
      log_message WARN "系统没有默认 IPv6 路由，可能无法获取 IPv6 地址。"
      return 1 # 没有 IPv6 路由，直接返回失败
  fi

  for site in "${WANIPSITE_v6[@]}"; do
    local ip=$(curl -s -6 "$site" | grep -Eo '([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}' | head -n 1)
    if [[ -n "$ip" && "$ip" != "::" ]]; then
      log_message INFO "通过 $site 获取到 IPv6 地址: $ip"
      echo "$ip"
      return 0
    fi
  done
  log_message ERROR "未能获取到 IPv6 地址。"
  return 1
}

# 函数：更新 DNS 记录
update_record() {
  local record_type="$1"
  local current_ip="$2"
  local ip_file="$DATA_DIR/${CFRECORD_NAME}_${record_type}.ip"
  local record_id_file="$DATA_DIR/${CFRECORD_NAME}_${record_type}.id"
  local record_id=""
  local zone_id=""
  
  log_message INFO "正在处理 ${CFRECORD_NAME} (类型: $record_type)..."

  # 加载上次缓存的 IP 地址和记录 ID
  if [ -f "$ip_file" ]; then
    local last_ip=$(cat "$ip_file")
  else
    local last_ip=""
  fi
  if [ -f "$record_id_file" ]; then
    record_id=$(cat "$record_id_file")
  else
    record_id=""
  fi

  # 检查是否需要更新
  if [[ "$last_ip" == "$current_ip" ]] && [ "$FORCE" == false ]; then
    log_message INFO "IP ($record_type) 未改变 ($current_ip)。无需更新。"
    echo -e "${BLUE}IP ($record_type) 未改变 ($current_ip)。无需更新。${NC}"
    return 0
  fi

  echo -e "${YELLOW}IP ($record_type) 已改变或强制更新 ($last_ip -> $current_ip)。正在更新...${NC}"
  log_message INFO "IP ($record_type) 已改变或强制更新 ($last_ip -> $current_ip)。"

  # 获取 Zone ID
  if [[ -z "$zone_id" ]]; then
    log_message INFO "正在获取 Zone ID..."
    zone_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
      -H "X-Auth-Email: $CFUSER" \
      -H "X-Auth-Key: $CFKEY" \
      -H "Content-Type: application/json")

    zone_id=$(echo "$zone_response" | jq -r '.result[0].id' 2>/dev/null)
    
    if [ -z "$zone_id" ] || [ "$zone_id" == "null" ]; then
      log_message ERROR "获取 Zone ID 失败。响应: $zone_response"
      echo -e "${RED}错误: 获取 Zone ID 失败。请检查 CFZONE_NAME 或 API 密钥。${NC}"
      local message="❌ *Cloudflare DDNS 错误* ❌

*获取 Zone ID 失败!*
域名: \`$CFZONE_NAME\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请检查您的 *CFZONE_NAME* 和 *API 密钥*。"
      send_tg_notification "$message"
      return 1
    fi
    log_message INFO "Zone ID: $zone_id"
  fi

  # 查找现有记录或创建新记录
  if [[ -z "$record_id" ]]; then
    log_message INFO "正在查找现有记录或创建新记录..."
    record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type&name=$CFRECORD_NAME" \
      -H "X-Auth-Email: $CFUSER" \
      -H "X-Auth-Key: $CFKEY" \
      -H "Content-Type: application/json")

    record_id=$(echo "$record_response" | jq -r '.result[0].id' 2>/dev/null)
    
    if [ -z "$record_id" ] || [ "$record_id" == "null" ]; then
      log_message INFO "未找到现有记录，尝试创建新记录。"
      echo -e "${YELLOW}未找到现有记录，正在创建新记录...${NC}"
      create_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$record_type\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$current_ip\",\"ttl\":$CFTTL,\"proxied\":true}") # 默认开启代理
      
      record_id=$(echo "$create_response" | jq -r '.result.id' 2>/dev/null)
      local success=$(echo "$create_response" | jq -r '.success' 2>/dev/null)

      if [[ "$success" == "true" && -n "$record_id" && "$record_id" != "null" ]]; then
        log_message SUCCESS "成功创建 DNS 记录 (${record_type}): $CFRECORD_NAME -> $current_ip"
        echo -e "${GREEN}✅ 成功创建 DNS 记录 (${record_type}): ${CFRECORD_NAME} -> ${current_ip}${NC}"
        echo "$record_id" > "$record_id_file" # 缓存记录 ID
        echo "$current_ip" > "$ip_file"       # 缓存新 IP
        local message="✅ *Cloudflare DDNS 更新成功* ✅

*记录类型:* \`$record_type\`
*域名:* \`$CFRECORD_NAME\`
*新 IP:* \`$current_ip\`
*操作:* 创建
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`"
        send_tg_notification "$message"
        return 0
      else
        log_message ERROR "创建 DNS 记录失败。响应: $create_response"
        echo -e "${RED}错误: 创建 DNS 记录失败。响应: ${create_response}${NC}"
        local message="❌ *Cloudflare DDNS 错误* ❌

*创建 DNS 记录失败!*
记录类型: \`$record_type\`
域名: \`$CFRECORD_NAME\`
目标 IP: \`$current_ip\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请检查 Cloudflare 响应。"
        send_tg_notification "$message"
        return 1
      fi
    else
      log_message INFO "找到现有记录 ID: $record_id"
      echo "$record_id" > "$record_id_file" # 缓存记录 ID
    fi
  fi

  # 更新现有记录
  log_message INFO "正在更新现有 DNS 记录 (${record_type}) ID: $record_id ..."
  update_response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
    -H "X-Auth-Email: $CFUSER" \
    -H "X-Auth-Key: $CFKEY" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"$record_type\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$current_ip\",\"ttl\":$CFTTL,\"proxied\":true}") # 默认开启代理

  local success=$(echo "$update_response" | jq -r '.success' 2>/dev/null)

  if [[ "$success" == "true" ]]; then
    log_message SUCCESS "成功更新 DNS 记录 (${record_type}): $CFRECORD_NAME -> $current_ip"
    echo -e "${GREEN}✅ 成功更新 DNS 记录 (${record_type}): ${CFRECORD_NAME} -> ${current_ip}${NC}"
    echo "$current_ip" > "$ip_file" # 缓存新 IP
    local message="✅ *Cloudflare DDNS 更新成功* ✅

*记录类型:* \`$record_type\`
*域名:* \`$CFRECORD_NAME\`
*新 IP:* \`$current_ip\`
*操作:* 更新
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`"
    send_tg_notification "$message"
    return 0
  else
    log_message ERROR "更新 DNS 记录失败。响应: $update_response"
    echo -e "${RED}错误: 更新 DNS 记录失败。响应: ${update_response}${NC}"
    local message="❌ *Cloudflare DDNS 错误* ❌

*更新 DNS 记录失败!*
记录类型: \`$record_type\`
域名: \`$CFRECORD_NAME\`
目标 IP: \`$current_ip\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请检查 Cloudflare 响应。"
    send_tg_notification "$message"
    return 1
  fi
}

# 函数：根据记录类型处理更新
process_record_type() {
  local type_to_process="$1"
  local current_ip=""

  case "$type_to_process" in
    "A")
      current_ip=$(get_wan_ip_v4)
      if [ -z "$current_ip" ]; then
        log_message ERROR "未能获取 IPv4 地址，跳过 A 记录更新。"
        echo -e "${RED}❌ 未能获取 IPv4 地址，跳过 A 记录更新。${NC}"
        return 1
      fi
      update_record "A" "$current_ip"
      ;;
    "AAAA")
      current_ip=$(get_wan_ip_v6)
      if [ -z "$current_ip" ]; then
        log_message WARN "未能获取 IPv6 地址，跳过 AAAA 记录更新。"
        echo -e "${YELLOW}⚠️ 未能获取 IPv6 地址，跳过 AAAA 记录更新。${NC}"
        # IPv6 获取失败不作为致命错误，只记录警告
        return 0 
      fi
      update_record "AAAA" "$current_ip"
      ;;
    *)
      log_message ERROR "不支持的记录类型: $type_to_process"
      echo -e "${RED}❌ 不支持的记录类型: ${type_to_process}${NC}"
      return 1
      ;;
  esac
}

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

# 函数：查看当前配置
show_current_config() {
  log_message INFO "正在显示当前配置..."
  clear
  echo -e "${CYAN}📋 当前 DDNS 配置 📋${NC}"
  if load_config; then
    echo -e "${GREEN}-------------------------------------------${NC}"
    echo -e "${BLUE}Cloudflare API 密钥: ${NC}${CFKEY:0:5}**********************"
    echo -e "${BLUE}Cloudflare 账户邮箱: ${NC}${CFUSER}"
    echo -e "${BLUE}域名区域:           ${NC}${CFZONE_NAME}"
    echo -e "${BLUE}记录名称:           ${NC}${CFRECORD_NAME}"
    echo -e "${BLUE}记录类型:           ${NC}${CFRECORD_TYPE}"
    echo -e "${BLUE}TTL:                ${NC}${CFTTL} 秒"
    echo -e "${BLUE}强制更新模式:       ${NC}${FORCE}"
    echo -e "${BLUE}Telegram Bot Token: ${NC}${TG_BOT_TOKEN:0:5}**********************"
    echo -e "${BLUE}Telegram Chat ID:   ${NC}${TG_CHAT_ID}"
    echo -e "${GREEN}-------------------------------------------${NC}"
  else
    echo -e "${RED}配置文件 ${CONFIG_FILE} 不存在或加载失败。${NC}"
    echo -e "${YELLOW}请先运行 '安装并配置 DDNS' 来设置。${NC}"
  fi
  read -p "按回车键返回主菜单..."
}

# 函数：查看日志
view_logs() {
  log_message INFO "正在显示最近的日志..."
  clear
  echo -e "${CYAN}📜 DDNS 日志 (最近 50 行) 📜${NC}"
  echo -e "${GREEN}-------------------------------------------${NC}"
  if [ -f "$LOG_FILE" ]; then
    tail -n 50 "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g' # 移除颜色代码
  else
    echo -e "${YELLOW}日志文件 ${LOG_FILE} 不存在。${NC}"
  fi
  echo -e "${GREEN}-------------------------------------------${NC}"
  read -p "按回车键返回主菜单..."
}


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
      ;;
    *)
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
