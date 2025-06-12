#!/usr/bin/env bash
# Cloudflare DDNS 管理脚本 - 优化版

# 严格的错误处理：
set -o errexit  # 任何命令失败时立即退出。
set -o nounset  # 使用未定义变量时报错。
set -o pipefail # 管道中任何命令失败时整个管道失败。

# 设置时区以便日志时间一致。如果需要特定时区，请修改此行。
export TZ="Asia/Shanghai"

# --- 配置路径 ---
CONFIG_DIR="/etc/cf-ddns"                 # 配置文件存储目录
DATA_DIR="/var/lib/cf-ddns"               # 数据文件存储目录 (例如 IP 缓存、上次轮换日期)
CONFIG_FILE="$CONFIG_DIR/config.conf"     # 主配置文件
LOG_FILE="/var/log/cf-ddns.log"           # 日志文件
LAST_ROTATED_DATE_FILE="$DATA_DIR/last_rotated_date" # 记录上次日志轮换日期的文件
IP_CACHE_FILE="$DATA_DIR/current_ip"      # IP 缓存文件
CRON_JOB_ID="CLOUDFLARE_DDNS_JOB"         # 定时任务的唯一标识符

# --- 默认配置参数 (将被配置文件覆盖) ---
CFKEY=""               # Cloudflare API 密钥
CFUSER=""              # Cloudflare 账户邮箱
CFZONE_NAME=""         # 域名区域 (例如：example.com)
CFRECORD_NAME=""       # 完整记录名称 (例如：host.example.com)
CFRECORD_TYPE="BOTH"   # 记录类型：A (IPv4) | AAAA (IPv6) | BOTH (双栈)
CFTTL=120              # DNS 记录 TTL 值 (120-86400 秒)
FORCE=false            # 强制更新模式 (忽略本地 IP 缓存，每次都更新)
TG_BOT_TOKEN=""        # Telegram 机器人 Token
TG_CHAT_ID=""          # Telegram 聊天 ID

# --- 公网 IP 检测服务 (多源冗余) ---
# 优先使用 HTTPS 以提高安全性，如果 curl 支持。
# 请注意，这些服务可能因网络状况或服务提供商而异。
IPV4_SERVICES=(
  "https://ipv4.icanhazip.com"
  "https://api.ipify.org"
  "https://ip.tool.lu"
  "https://ipinfo.io/ip"
  "https://ifconfig.me/ip"
)
IPV6_SERVICES=(
  "https://ipv6.icanhazip.com"
  "https://api6.ipify.org"
  "https://ip.tool.lu"
  "https://ipinfo.io/ip"
  "https://ifconfig.me/ip"
)

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色 - 重置为默认

# =====================================================================
# 核心功能函数
# =====================================================================

# 函数：记录日志
# 参数: $1 - 日志级别 (INFO, WARN, ERROR, SUCCESS)
# 参数: $2 - 日志消息
log_message() {
  local level="$1"
  local message="$2"
  local timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE" # 输出到控制台并追加到日志文件
}

# 函数：发送 Telegram 通知
# 参数: $1 - 消息内容
send_telegram_notification() {
  local message="$1"
  if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    local URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    local response=$(curl -s -X POST "$URL" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "parse_mode=Markdown" \
      -d "text=${message}" \
      --connect-timeout 5) # 设置连接超时，避免长时间阻塞
    if echo "$response" | grep -q '"ok":true'; then
      log_message INFO "Telegram 通知发送成功。"
    else
      log_message WARN "Telegram 通知发送失败: $response"
    fi
  else
    log_message INFO "Telegram 配置未设置，跳过通知。"
  fi
}

# 函数：获取公网 IPv4 地址
get_ipv4() {
  for service in "${IPV4_SERVICES[@]}"; do
    local ip=$(curl -sL -m 5 --retry 3 --retry-delay 1 "$service" 2>/dev/null | grep -E -o "([0-9]{1,3}\.){3}[0-9]{1,3}")
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  done
  log_message ERROR "未能获取 IPv4 地址。"
  return 1
}

# 函数：获取公网 IPv6 地址
get_ipv6() {
  for service in "${IPV6_SERVICES[@]}"; do
    local ip=$(curl -sL -m 5 --retry 3 --retry-delay 1 "$service" 2>/dev/null | grep -E -o "([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}")
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  done
  log_message ERROR "未能获取 IPv6 地址。"
  return 1
}

# 函数：获取 Cloudflare 区域 ID
# 参数: $1 - 域名区域名称 (CFZONE_NAME)
get_zone_id() {
  local zone_name="$1"
  local zone_id=$(curl -sL -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" \
    -H "X-Auth-Email: $CFUSER" \
    -H "X-Auth-Key: $CFKEY" \
    -H "Content-Type: application/json" \
    --connect-timeout 10 | jq -r '.result[] | .id')

  if [[ -z "$zone_id" ]]; then
    log_message ERROR "未能获取区域 ID (Zone ID) for $zone_name。请检查域名区域名称和 Cloudflare 凭据。"
    send_telegram_notification "DDNS 错误: 获取区域 ID 失败 for $zone_name。请检查配置。"
    return 1
  fi
  echo "$zone_id"
  return 0
}

# 函数：获取 Cloudflare DNS 记录 ID
# 参数: $1 - 区域 ID (Zone ID)
# 参数: $2 - 记录名称 (CFRECORD_NAME)
# 参数: $3 - 记录类型 (A/AAAA)
get_record_id() {
  local zone_id="$1"
  local record_name="$2"
  local record_type="$3"
  local record_id=$(curl -sL -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type&name=$record_name" \
    -H "X-Auth-Email: $CFUSER" \
    -H "X-Auth-Key: $CFKEY" \
    -H "Content-Type: application/json" \
    --connect-timeout 10 | jq -r '.result[] | .id')

  if [[ -z "$record_id" ]]; then
    log_message ERROR "未能获取记录 ID (Record ID) for $record_name ($record_type)。请检查记录名称和类型。"
    return 1
  fi
  echo "$record_id"
  return 0
}

# 函数：更新 Cloudflare DNS 记录
# 参数: $1 - 区域 ID (Zone ID)
# 参数: $2 - 记录 ID (Record ID)
# 参数: $3 - 记录名称 (CFRECORD_NAME)
# 参数: $4 - 记录类型 (A/AAAA)
# 参数: $5 - 新 IP 地址
# 参数: $6 - TTL
update_record() {
  local zone_id="$1"
  local record_id="$2"
  local record_name="$3"
  local record_type="$4"
  local new_ip="$5"
  local ttl="$6"

  log_message INFO "正在更新记录: $record_name ($record_type) 到 IP: $new_ip (TTL: $ttl)..."
  local response=$(curl -sL -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
    -H "X-Auth-Email: $CFUSER" \
    -H "X-Auth-Key: $CFKEY" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$new_ip\",\"ttl\":$ttl,\"proxied\":false}" \
    --connect-timeout 10)

  if echo "$response" | grep -q '"success":true'; then
    log_message SUCCESS "成功更新记录: $record_name ($record_type) 到 IP: $new_ip。"
    send_telegram_notification "DDNS 更新成功: $record_name ($record_type) 已更新为 $new_ip。"
    return 0
  else
    log_message ERROR "更新记录失败: $record_name ($record_type)。响应: $response"
    send_telegram_notification "DDNS 更新失败: $record_name ($record_type)。原因: $response"
    return 1
  fi
}

# 函数：执行 DDNS 更新的主要逻辑
run_ddns_update() {
  log_message INFO "--- DDNS 更新开始 ---"

  # 确保配置存在且有效
  if ! load_config; then
    log_message ERROR "无法加载配置或配置不完整。请运行 'sudo $(basename "$0") install' 进行配置。"
    send_telegram_notification "DDNS 错误: 配置缺失或无效。请运行安装程序。"
    return 1
  fi

  # 检查关键配置项
  if [[ -z "$CFKEY" || -z "$CFUSER" || -z "$CFZONE_NAME" || -z "$CFRECORD_NAME" ]]; then
    log_message ERROR "关键配置项缺失 (API 密钥、邮箱、区域名称或记录名称)。请运行 'sudo $(basename "$0") modify' 进行修改。"
    send_telegram_notification "DDNS 错误: 关键配置项缺失。请运行修改程序。"
    return 1
  fi

  local zone_id=$(get_zone_id "$CFZONE_NAME")
  if [[ -z "$zone_id" ]]; then
    return 1 # get_zone_id 已记录错误
  fi

  local old_ip_v4=""
  local old_ip_v6=""
  local new_ip_v4=""
  local new_ip_v6=""
  local updated_v4=false
  local updated_v6=false

  # 读取缓存的 IP 地址
  if [ -f "$IP_CACHE_FILE" ]; then
    old_ip_v4=$(grep "ipv4=" "$IP_CACHE_FILE" | cut -d= -f2 || true)
    old_ip_v6=$(grep "ipv6=" "$IP_CACHE_FILE" | cut -d= -f2 || true)
  fi

  log_message INFO "当前缓存 IPv4: ${old_ip_v4:-未缓存}"
  log_message INFO "当前缓存 IPv6: ${old_ip_v6:-未缓存}"

  # 处理 IPv4 (A 记录)
  if [[ "$CFRECORD_TYPE" == "A" || "$CFRECORD_TYPE" == "BOTH" ]]; then
    new_ip_v4=$(get_ipv4)
    if [[ -n "$new_ip_v4" ]]; then
      log_message INFO "检测到当前 IPv4: $new_ip_v4"
      if [[ "$new_ip_v4" != "$old_ip_v4" || "$FORCE" == "true" ]]; then
        local record_id_v4=$(get_record_id "$zone_id" "$CFRECORD_NAME" "A")
        if [[ -n "$record_id_v4" ]]; then
          if update_record "$zone_id" "$record_id_v4" "$CFRECORD_NAME" "A" "$new_ip_v4" "$CFTTL"; then
            updated_v4=true
          fi
        fi
      else
        log_message INFO "IPv4 未改变 ($new_ip_v4)，无需更新。"
      fi
    fi
  fi

  # 处理 IPv6 (AAAA 记录)
  if [[ "$CFRECORD_TYPE" == "AAAA" || "$CFRECORD_TYPE" == "BOTH" ]]; then
    new_ip_v6=$(get_ipv6)
    if [[ -n "$new_ip_v6" ]]; then
      log_message INFO "检测到当前 IPv6: $new_ip_v6"
      if [[ "$new_ip_v6" != "$old_ip_v6" || "$FORCE" == "true" ]]; then
        local record_id_v6=$(get_record_id "$zone_id" "$CFRECORD_NAME" "AAAA")
        if [[ -n "$record_id_v6" ]]; then
          if update_record "$zone_id" "$record_id_v6" "$CFRECORD_NAME" "AAAA" "$new_ip_v6" "$CFTTL"; then
            updated_v6=true
          fi
        fi
      else
        log_message INFO "IPv6 未改变 ($new_ip_v6)，无需更新。"
      fi
    fi
  fi

  # 更新 IP 缓存
  if [[ "$updated_v4" == "true" || "$updated_v6" == "true" || "$FORCE" == "true" ]]; then
    log_message INFO "正在更新 IP 缓存文件..."
    echo "ipv4=${new_ip_v4:-}" > "$IP_CACHE_FILE"
    echo "ipv6=${new_ip_v6:-}" >> "$IP_CACHE_FILE"
    log_message SUCCESS "IP 缓存文件更新完成。"
  else
    log_message INFO "IP 未发生变化且未强制更新，跳过 IP 缓存更新。"
  fi

  log_message INFO "--- DDNS 更新结束 ---"
}

# =====================================================================
# 配置管理函数
# =====================================================================

# 函数：加载配置文件
load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    log_message WARN "配置文件 ($CONFIG_FILE) 不存在。"
    return 1 # 文件不存在
  fi
  # 使用 source 命令加载配置文件
  source "$CONFIG_FILE"
  log_message INFO "配置已从 $CONFIG_FILE 加载。"
  return 0
}

# 函数：保存配置文件
save_config() {
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" # 确保目录存在
  echo "# Cloudflare DDNS 配置" > "$CONFIG_FILE"
  echo "CFKEY=\"$CFKEY\"" >> "$CONFIG_FILE"
  echo "CFUSER=\"$CFUSER\"" >> "$CONFIG_FILE"
  echo "CFZONE_NAME=\"$CFZONE_NAME\"" >> "$CONFIG_FILE"
  echo "CFRECORD_NAME=\"$CFRECORD_NAME\"" >> "$CONFIG_FILE"
  echo "CFRECORD_TYPE=\"$CFRECORD_TYPE\"" >> "$CONFIG_FILE"
  echo "CFTTL=$CFTTL" >> "$CONFIG_FILE"
  echo "FORCE=$FORCE" >> "$CONFIG_FILE"
  echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" >> "$CONFIG_FILE"
  echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" # 设置只读权限以保护敏感信息
  log_message INFO "配置已保存到 $CONFIG_FILE。"
}

# 函数：交互式配置 DDNS
interactive_config() {
  log_message INFO "正在进入交互式配置模式..."
  echo -e "${CYAN}--- DDNS 配置 ---${NC}"
  
  # 加载现有配置
  load_config || true # 如果文件不存在也不报错，继续收集输入

  read -rp "$(echo -e "${PURPLE}请输入您的 Cloudflare API 密钥 (Global API Key): ${NC}[${CFKEY:-未设置}] ")" input
  [ -n "$input" ] && CFKEY="$input"

  read -rp "$(echo -e "${PURPLE}请输入您的 Cloudflare 账户邮箱: ${NC}[${CFUSER:-未设置}] ")" input
  [ -n "$input" ] && CFUSER="$input"

  # 先获取 CFZONE_NAME
  read -rp "$(echo -e "${PURPLE}请输入您的域名区域 (例如: example.com): ${NC}[${CFZONE_NAME:-未设置}] ")" input
  [ -n "$input" ] && CFZONE_NAME="$input"

  # 根据 CFZONE_NAME 自动生成 CFRECORD_NAME 的建议值
  local default_cfrecord_name="${CFRECORD_NAME:-}" # 保持现有值
  if [[ -z "$default_cfrecord_name" && -n "$CFZONE_NAME" ]]; then
    default_cfrecord_name="host.${CFZONE_NAME}"
  fi

  read -rp "$(echo -e "${PURPLE}请输入您的完整记录名称 (例如: host.example.com): ${NC}[${default_cfrecord_name}] ")" input
  # 如果用户输入为空，则使用建议值；否则使用用户输入的值
  if [[ -n "$input" ]]; then
      CFRECORD_NAME="$input"
  elif [[ -n "$default_cfrecord_name" ]]; then
      CFRECORD_NAME="$default_cfrecord_name"
  fi


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
      CFTTL=120 # 强制设置为默认值
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

  # Telegram 通知配置
  read -rp "$(echo -e "${PURPLE}请输入 Telegram 机器人 Token (可选): ${NC}[${TG_BOT_TOKEN:-未设置}] ")" input_tg_token
  [ -n "$input_tg_token" ] && TG_BOT_TOKEN="$input_tg_token"

  read -rp "$(echo -e "${PURPLE}请输入 Telegram 聊天 ID (可选): ${NC}[${TG_CHAT_ID:-未设置}] ")" input_tg_chat_id
  [ -n "$input_tg_chat_id" ] && TG_CHAT_ID="$input_tg_chat_id"

  save_config # 保存配置
  log_message INFO "交互式配置完成。"
  echo -e "${GREEN}配置已保存。${NC}"
  sleep 1
}

# 函数：安装 DDNS 服务 (设置定时任务)
install_ddns() {
  log_message INFO "正在安装 DDNS 服务..."
  echo -e "${CYAN}--- 安装 DDNS 服务 ---${NC}"

  # 确保依赖已安装
  log_message INFO "检查安装依赖 (curl, jq, crontab)..."
  local dependencies=("curl" "jq")
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      log_message ERROR "依赖 '$dep' 未找到。请安装: sudo apt install $dep 或 sudo yum install $dep"
      echo -e "${RED}❌ 错误: 缺少依赖 '${dep}'。请先安装。${NC}"
      return 1
    fi
  done
  log_message INFO "所有依赖已检查通过。"

  interactive_config # 运行交互式配置

  # 验证关键配置项是否已设置
  if [[ -z "$CFKEY" || -z "$CFUSER" || -z "$CFZONE_NAME" || -z "$CFRECORD_NAME" ]]; then
    log_message ERROR "关键配置项缺失，无法设置定时任务。"
    echo -e "${RED}❌ 错误: 关键配置项未设置，无法设置定时任务。请重新运行配置。${NC}"
    return 1
  fi

  # 添加定时任务
  # 每 5 分钟运行一次脚本的 update 命令
  log_message INFO "正在添加定时任务..."
  (crontab -l 2>/dev/null | grep -v "$CRON_JOB_ID" || true; echo "*/5 * * * * $DDNS_SCRIPT_PATH update # $CRON_JOB_ID") | crontab -
  log_message SUCCESS "定时任务已成功添加。"
  echo -e "${GREEN}🎉 DDNS 服务已安装并配置完成！${NC}"
  echo -e "${GREEN}脚本将每 5 分钟自动更新一次 DNS 记录。${NC}"
  sleep 1
}

# 函数：修改配置
modify_config() {
  log_message INFO "正在进入修改配置模式..."
  echo -e "${CYAN}--- 修改 DDNS 配置 ---${NC}"
  if ! load_config; then
    echo -e "${YELLOW}警告: 配置文件不存在或无法加载。将从头开始配置。${NC}"
  fi
  interactive_config # 运行交互式配置，它会加载并允许修改现有值
  echo -e "${GREEN}配置修改完成。${NC}"
  sleep 1
}

# 函数：卸载 DDNS 服务
uninstall_ddns() {
  log_message INFO "正在卸载 DDNS 服务..."
  echo -e "${CYAN}--- 卸载 DDNS 服务 ---${NC}"

  # 删除定时任务
  log_message INFO "正在删除定时任务..."
  (crontab -l 2>/dev/null | grep -v "$CRON_JOB_ID" || true) | crontab -
  log_message SUCCESS "定时任务已成功删除。"

  # 删除配置文件和数据目录
  log_message INFO "正在删除配置文件和数据目录..."
  if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR" && log_message SUCCESS "已删除配置目录: $CONFIG_DIR" || log_message ERROR "删除配置目录失败: $CONFIG_DIR"
  fi
  if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR" && log_message SUCCESS "已删除数据目录: $DATA_DIR" || log_message ERROR "删除数据目录失败: $DATA_DIR"
  fi

  # 删除日志文件 (可选，但建议在卸载时清理)
  if [ -f "$LOG_FILE" ]; then
    rm -f "$LOG_FILE" && log_message SUCCESS "已删除日志文件: $LOG_FILE" || log_message ERROR "删除日志文件失败: $LOG_FILE"
  fi

  # 删除脚本自身 (如果是在安装目录中)
  # 注意：在 install.sh 调用 uninstall 时，不要在这里删除自己
  # 除非是用户手动运行 cf-ddns.sh uninstall
  if [ -f "$DDNS_SCRIPT_PATH" ]; then
    read -rp "$(echo -e "${YELLOW}是否要删除 DDNS 脚本文件本身 (${DDNS_SCRIPT_PATH})？ (y/n): ${NC}")" confirm_delete_script
    if [[ "$confirm_delete_script" =~ ^[yY]$ ]]; then
      rm -f "$DDNS_SCRIPT_PATH" && log_message SUCCESS "已删除 DDNS 脚本文件: $DDNS_SCRIPT_PATH" || log_message ERROR "删除 DDNS 脚本文件失败: $DDNS_SCRIPT_PATH"
    fi
  fi

  log_message SUCCESS "DDNS 服务已完全卸载。"
  echo -e "${GREEN}🎉 DDNS 服务已成功卸载。${NC}"
  sleep 1
}

# =====================================================================
# 日志管理
# =====================================================================

# 函数：按天轮换日志
rotate_logs() {
  log_message INFO "正在检查日志轮换..."
  local current_date=$(date +"%Y-%m-%d")
  local last_rotated_date=""

  mkdir -p "$DATA_DIR" # 确保数据目录存在

  if [ -f "$LAST_ROTATED_DATE_FILE" ]; then
    last_rotated_date=$(cat "$LAST_ROTATED_DATE_FILE")
  fi

  if [[ "$current_date" != "$last_rotated_date" ]]; then
    log_message INFO "日期已变更，执行日志轮换。"
    if [ -f "$LOG_FILE" ]; then
      local timestamp=$(date +"%Y%m%d_%H%M%S")
      mv "$LOG_FILE" "${LOG_FILE}.${timestamp}.old"
      log_message SUCCESS "已将旧日志文件 ${LOG_FILE}.${timestamp}.old 归档。"
    else
      log_message INFO "日志文件不存在，无需归档。"
    fi
    # 创建新的日志文件或确保其存在
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE" # 设置日志文件权限，通常为 root:adm 或 root:syslog 可读写
    chown root:root "$LOG_FILE" # 确保所有者和组正确

    echo "$current_date" > "$LAST_ROTATED_DATE_FILE"
    log_message SUCCESS "日志轮换完成，新日期记录为 $current_date。"
  else
    log_message INFO "日志已在今日轮换过，跳过。"
  fi
}

# =====================================================================
# 主菜单和命令行参数处理
# =====================================================================

# 函数：显示主菜单
show_main_menu() {
  clear # 清屏
  echo -e "${CYAN}=======================================${NC}"
  echo -e "${CYAN}  Cloudflare DDNS 管理脚本 - 主菜单  ${NC}"
  echo -e "${CYAN}=======================================${NC}"
  echo -e "${GREEN}1) 安装/重新安装 DDNS 服务 ${NC}(首次运行或重新配置)"
  echo -e "${GREEN}2) 修改 DDNS 配置 ${NC}(更新凭据/域名等)"
  echo -e "${GREEN}3) 立即运行 DDNS 更新 ${NC}(手动触发一次更新)"
  echo -e "${GREEN}4) 卸载 DDNS 服务 ${NC}(移除脚本和定时任务)"
  echo -e "${GREEN}5) 查看最新日志 ${NC}"
  echo -e "${RED}6) 退出${NC}"
  echo -e "${CYAN}=======================================${NC}"
  read -rp "$(echo -e "${PURPLE}请选择一个选项 [1-6]: ${NC}")" main_choice
}

# 在脚本开始时执行日志轮换
rotate_logs

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
    # 添加一个直接进入主菜单的参数，例如 'menu'
    menu)
      log_message INFO "命令行参数: menu，将显示主菜单。"
      # 继续执行下面的主菜单循环
      ;;
    *)\
      log_message ERROR "无效的命令行参数: $1"
      echo -e "${RED}❌ 无效参数: ${1}${NC}"
      echo -e "${YELLOW}用法: ${NC}$(basename "$0") ${GREEN}[update|install|modify|uninstall|menu]${NC}"
      exit 1
      ;;
  esac
fi

# 如果没有参数或参数为 'menu'，则显示主菜单
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
      run_ddns_update
      ;;
    4)
      uninstall_ddns
      ;;
    5)
      if [ -f "$LOG_FILE" ]; then
        echo -e "${CYAN}--- 最新日志 (${LOG_FILE}) ---${NC}"
        tail -n 50 "$LOG_FILE" # 显示最近50行日志
        echo -e "${CYAN}-------------------------------${NC}"
        read -rp "$(echo -e "${PURPLE}按任意键继续...${NC}")"
      else
        echo -e "${YELLOW}日志文件不存在: ${LOG_FILE}${NC}"
        read -rp "$(echo -e "${PURPLE}按任意键继续...${NC}")"
      fi
      ;;
    6)
      echo -e "${GREEN}感谢使用，再见！${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}无效选项，请重新输入。${NC}"
      sleep 1
      ;;
  esac
done
