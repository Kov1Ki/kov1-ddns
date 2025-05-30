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
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${BLUE}        CloudFlare DDNS 管理脚本              ${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${GREEN} 1. 安装和配置 DDNS${NC}"
  echo -e "${GREEN} 2. 修改 DDNS 配置${NC}"
  echo -e "${GREEN} 3. 卸载 DDNS${NC}"
  echo -e "${GREEN} 4. 查看当前配置${NC}"
  echo -e "${GREEN} 5. 手动运行更新${NC}"
  echo -e "${GREEN} 6. 查看日志${NC}"
  echo -e "${GREEN} 7. 配置 Telegram 通知${NC}"
  echo -e "${GREEN} 8. 退出脚本${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  echo
  read -p "请输入您的选择 [1-8]: " main_choice
}

# 函数：初始化目录结构
init_dirs() {
  log_message INFO "正在初始化目录..."
  local dirs=("$CONFIG_DIR" "$DATA_DIR")
  for dir in "${dirs[@]}"; do
    if [ ! -d "$dir" ]; then
      log_message INFO "正在创建目录: $dir"
      if ! mkdir -p "$dir"; then
        log_message ERROR "创建目录失败: $dir"
        exit 1
      fi
      if ! chmod 700 "$dir"; then
        log_message ERROR "设置目录权限失败: $dir"
        exit 1
      fi
    fi
  done
  
  if [ ! -f "$LOG_FILE" ]; then
    log_message INFO "正在创建日志文件: $LOG_FILE"
    if ! touch "$LOG_FILE"; then
      log_message ERROR "创建日志文件失败: $LOG_FILE"
      exit 1
    fi
    if ! chmod 600 "$LOG_FILE"; then
      log_message ERROR "设置日志文件权限失败: $LOG_FILE"
      exit 1
    fi
  fi
  log_message INFO "目录初始化完成。"
}

# 函数：轮换日志，保留最近 7 天的日志
rotate_logs() {
  local log_file="$1"
  local max_days=7
  if [ -f "$log_file" ]; then
    # 计算日志文件的年龄（秒）
    local file_mtime=$(stat -c %Y "$log_file") # 修改时间（自纪元以来的秒数）
    local current_time=$(date +%s)
    local age=$((current_time - file_mtime))
    local max_age=$((max_days * 24 * 60 * 60))

    if [ "$age" -gt "$max_age" ]; then
      log_message INFO "日志文件 '$log_file' 已超过 $max_days 天 ($((age / 86400)) 天)。正在删除..."
      if rm -f "$log_file"; then
        log_message SUCCESS "日志文件已删除: $log_file"
      else
        log_message ERROR "删除旧日志文件失败: $log_file"
      fi
    fi
  fi
}

# =====================================================================
# 配置函数
# =====================================================================

# 函数：交互式配置向导
interactive_config() {
  echo
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${BLUE}      CloudFlare DDNS 配置向导                ${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  
  # Cloudflare API 密钥
  while :; do
    read -p "请输入 Cloudflare API 密钥: " CFKEY
    if [ -z "$CFKEY" ]; then
      echo -e "${RED}错误: API 密钥不能为空!${NC}"
    elif [[ "$CFKEY" =~ ^[a-zA-Z0-9]{37}$ ]]; then
      break
    else
      echo -e "${RED}错误: 无效的 API 密钥格式 (应为 37 位字母数字字符)。${NC}"
    fi
  done
  
  # Cloudflare 账户邮箱
  while :; do
    read -p "请输入 Cloudflare 账户邮箱: " CFUSER
    if [ -z "$CFUSER" ]; then
      echo -e "${RED}错误: 账户邮箱不能为空!${NC}"
    elif [[ "$CFUSER" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      echo -e "${RED}错误: 无效的邮箱格式!${NC}"
    fi
  done
  
  # 域名区域
  while :; do
    read -p "请输入域名区域 (例如：example.com): " CFZONE_NAME
    if [ -z "$CFZONE_NAME" ]; then
      echo -e "${RED}错误: 域名区域不能为空!${NC}"
    elif [[ "$CFZONE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      echo -e "${RED}错误: 无效的域名格式!${NC}"
    fi
  done
  
  # 记录名称
  while :; do
    read -p "请输入主机记录 (例如：home 或 host.example.com): " CFRECORD_NAME_INPUT
    if [ -z "$CFRECORD_NAME_INPUT" ]; then
      echo -e "${RED}错误: 主机记录不能为空!${NC}"
    else
      # 如果未包含域名，则自动补全为 FQDN
      if [[ "$CFRECORD_NAME_INPUT" == "@" ]]; then # 允许 '@' 表示根域名
        CFRECORD_NAME="$CFZONE_NAME"
      elif [[ "$CFRECORD_NAME_INPUT" != *"$CFZONE_NAME" ]]; then
        CFRECORD_NAME="${CFRECORD_NAME_INPUT}.${CFZONE_NAME}"
        echo -e "${GREEN}提示: 已自动补全为完整域名: $CFRECORD_NAME${NC}"
      else
        CFRECORD_NAME="$CFRECORD_NAME_INPUT"
      fi
      
      # 验证 FQDN 格式
      if [[ "$CFRECORD_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ || "$CFRECORD_NAME" == "$CFZONE_NAME" ]]; then
        break
      else
        echo -e "${RED}错误: 主机记录格式无效!${NC}"
      fi
    fi
  done
  
  # 记录类型
  while :; do
    echo -e "${BLUE}请选择记录类型:${NC}"
    echo "1) IPv4 (A 记录)"
    echo "2) IPv6 (AAAA 记录)"
    echo "3) 双栈 (A 和 AAAA 记录)"
    read -p "请输入选项 [1-3] (默认 3): " type_choice
    case "${type_choice:-3}" in
      1) CFRECORD_TYPE="A"; break ;;
      2) CFRECORD_TYPE="AAAA"; break ;;
      3) CFRECORD_TYPE="BOTH"; break ;;
      *) echo -e "${RED}无效选择，请重新输入!${NC}" ;;
    esac
  done
  
  # TTL 设置
  while :; do
    read -p "请输入 TTL 值 (120-86400，默认 120): " ttl_input
    if [ -z "$ttl_input" ]; then
      CFTTL=120 # 如果为空则设置默认值
      break
    elif [[ "$ttl_input" =~ ^[0-9]+$ ]] && [ "$ttl_input" -ge 120 ] && [ "$ttl_input" -le 86400 ]; then
      CFTTL="$ttl_input"
      break
    else
      echo -e "${RED}错误: TTL 值必须是 120 到 86400 之间的整数!${NC}"
    fi
  done
  
  # 保存配置
  save_config
  
  echo
  echo -e "${GREEN}配置已保存到: $CONFIG_FILE${NC}"
  echo -e "${YELLOW}==============================================${NC}"
}

# 函数：配置 Telegram 通知
configure_telegram() {
  echo
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${BLUE}        Telegram 通知配置                     ${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  
  # 加载现有配置
  load_config || true # 如果在初始设置期间找不到配置，则不退出
  
  # 显示当前配置
  if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    echo -e "${GREEN}Telegram 通知功能当前已配置。${NC}"
    echo "机器人 Token: ${TG_BOT_TOKEN:0:4}****${TG_BOT_TOKEN: -4}"
    echo "聊天 ID: $TG_CHAT_ID"
    echo
    read -p "您想重新配置吗？ [y/N]: " reconfigure
    if [[ ! "${reconfigure,,}" =~ ^y$ ]]; then
      log_message INFO "用户跳过 Telegram 配置。"
      return 0
    fi
  fi
  
  # 询问是否启用通知
  read -p "您想启用 Telegram 通知吗？ [Y/n]: " enable_tg
  if [[ "${enable_tg,,}" =~ ^n$ ]]; then
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    save_config
    log_message INFO "Telegram 通知功能已禁用。"
    echo -e "${YELLOW}Telegram 通知功能已禁用。${NC}"
    return 0
  fi
  
  # 获取 Telegram 机器人 Token
  while :; do
    read -p "请输入 Telegram 机器人 Token: " TG_BOT_TOKEN
    if [ -z "$TG_BOT_TOKEN" ]; then
      echo -e "${RED}错误: Token 不能为空!${NC}"
    elif [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
      break
    else
      echo -e "${RED}错误: 无效的 Token 格式!${NC}"
    fi
  done
  
  # 获取 Telegram 聊天 ID
  while :; do
    read -p "请输入 Telegram 聊天 ID: " TG_CHAT_ID
    if [ -z "$TG_CHAT_ID" ]; then
      echo -e "${RED}错误: 聊天 ID 不能为空!${NC}"
    elif [[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]]; then # 群组的聊天 ID 可以是负数
      break
    else
      echo -e "${RED}错误: 聊天 ID 必须是数字!${NC}"
    fi
  done
  
  # 保存配置
  save_config
  
  # 发送测试消息
  log_message INFO "正在发送 Telegram 测试消息..."
  echo -e "${BLUE}正在发送测试消息...${NC}"
  if send_tg_notification "🔔 *Cloudflare DDNS 测试通知* ✅ Telegram 通知配置成功!
  域名: \`$CFRECORD_NAME\`
  记录类型: \`$CFRECORD_TYPE\`
  时间: $(date +"%Y-%m-%d %H:%M:%S %Z")"; then
    echo -e "${GREEN}测试消息发送成功! 请检查 Telegram。${NC}"
    log_message SUCCESS "Telegram 测试消息发送成功。"
  else
    echo -e "${RED}发送测试消息失败! 请检查配置。${NC}"
    log_message ERROR "发送 Telegram 测试消息失败。"
  fi
  
  echo -e "${GREEN}Telegram 通知配置已保存。${NC}"
}

# 函数：保存配置到文件
save_config() {
  log_message INFO "正在保存配置到 $CONFIG_FILE..."
  {
    echo "# CloudFlare DDNS 配置文件"
    echo "# 生成时间: $(date)"
    echo ""
    echo "CFKEY='$CFKEY'"
    echo "CFUSER='$CFUSER'"
    echo "CFZONE_NAME='$CFZONE_NAME'"
    echo "CFRECORD_NAME='$CFRECORD_NAME'"
    echo "CFRECORD_TYPE='$CFRECORD_TYPE'"
    echo "CFTTL=$CFTTL"
    echo "FORCE=$FORCE"
    # 确保变量被引用，以防止包含空格或特殊字符时出现问题
    echo "TG_BOT_TOKEN='${TG_BOT_TOKEN}'"
    echo "TG_CHAT_ID='${TG_CHAT_ID}'"
  } > "$CONFIG_FILE"
  
  if [ $? -eq 0 ]; then
    chmod 600 "$CONFIG_FILE"
    log_message SUCCESS "配置已保存并设置了 $CONFIG_FILE 的权限。"
  else
    log_message ERROR "保存配置到 $CONFIG_FILE 失败。"
    exit 1
  fi
}

# 函数：从文件加载配置
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    log_message INFO "正在从 $CONFIG_FILE 加载配置..."
    # 使用 'source' 加载变量。
    # 使用 set -a 自动导出所有加载的变量，然后取消设置。
    set -a
    . "$CONFIG_FILE"
    set +a
    log_message INFO "配置已加载。"
    return 0
  fi
  log_message WARN "找不到配置文件: $CONFIG_FILE"
  return 1
}

# 函数：添加定时任务
add_cron_job() {
  local script_path="$(realpath "$0")"
  
  log_message INFO "正在检查 $script_path 的现有定时任务..."
  # 通过 ID 或脚本路径检查定时任务是否已存在
  if crontab -l 2>/dev/null | grep -q "$CRON_JOB_ID"; then
    log_message INFO "找到现有定时任务，正在更新..."
    remove_cron_job
  fi
  
  # 定义定时任务调度和命令
  local cron_schedule="*/2 * * * *" # 每 2 分钟
  local cron_command="$cron_schedule $script_path update >> '$LOG_FILE' 2>&1 # $CRON_JOB_ID"
  
  # 添加定时任务
  (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
  
  if [ $? -eq 0 ]; then
    log_message SUCCESS "定时任务已添加: '$cron_schedule $script_path update'。"
    echo -e "${GREEN}定时任务已添加: 每 2 分钟运行一次。${NC}"
    echo -e "日志文件: $LOG_FILE"
  else
    log_message ERROR "添加定时任务失败。"
    echo -e "${RED}错误: 添加定时任务失败。请检查您的 crontab 设置。${NC}"
    exit 1
  fi
}

# 函数：移除定时任务
remove_cron_job() {
  local script_path="$(realpath "$0")"
  local script_name=$(basename "$script_path")
  
  log_message INFO "正在尝试移除与 $script_name 或 $CRON_JOB_ID 相关的定时任务..."
  
  # 检查定时任务是否存在
  local cron_exists=$(crontab -l 2>/dev/null | grep -c -e "$CRON_JOB_ID" -e "$script_name" -e "$script_path")
  
  if [ "$cron_exists" -gt 0 ]; then
    log_message INFO "找到 $cron_exists 个要移除的定时任务。"
    echo -e "${BLUE}正在移除 $cron_exists 个定时任务...${NC}"
    
    local temp_cron=$(mktemp)
    if crontab -l 2>/dev/null | grep -v -e "$CRON_JOB_ID" -e "$script_name" -e "$script_path" > "$temp_cron"; then
      if crontab "$temp_cron"; then
        log_message SUCCESS "成功移除了定时任务。"
        echo -e "${GREEN}成功移除了定时任务。${NC}"
      else
        log_message ERROR "未能应用来自 $temp_cron 的修改后的 crontab。"
        echo -e "${RED}错误: 未能应用修改后的 crontab。请检查您的 crontab 设置。${NC}"
        return 1
      fi
    else
      log_message ERROR "未能过滤 crontab 以移除条目。"
      echo -e "${RED}错误: 未能过滤 crontab。请检查您的 crontab 设置。${NC}"
      return 1
    fi
    rm -f "$temp_cron"
    return 0
  else
    log_message INFO "未找到现有定时任务可供移除。"
    echo -e "${YELLOW}未找到要移除的定时任务。${NC}"
    return 0
  fi
}

# 函数：卸载 DDNS
uninstall_ddns() {
  echo -e "${YELLOW}正在开始 DDNS 卸载...${NC}"
  log_message INFO "正在启动 DDNS 卸载过程。"
  
  # 移除定时任务
  if ! remove_cron_job; then
    echo -e "${RED}警告: 移除定时任务失败。手动干预可能需要。${NC}"
    log_message WARN "卸载期间移除定时任务失败。"
  fi
  
  # 从系统路径移除脚本
  local system_script_path="/usr/local/bin/cf-ddns"
  if [ -f "$system_script_path" ]; then
    log_message INFO "正在删除系统脚本: $system_script_path"
    if rm -f "$system_script_path"; then
      echo -e "${GREEN}已删除系统脚本: $system_script_path${NC}"
    else
      log_message ERROR "删除系统脚本失败: $system_script_path"
      echo -e "${RED}错误: 删除系统脚本失败: $system_script_path${NC}"
    fi
  fi
  
  # 移除快捷方式链接
  local shortcut_link="/usr/local/bin/d"
  if [ -L "$shortcut_link" ] || [ -f "$shortcut_link" ]; then # 检查它是否是链接或文件以增加健壮性
    log_message INFO "正在删除快捷方式链接: $shortcut_link"
    if rm -f "$shortcut_link"; then
      echo -e "${GREEN}已删除快捷方式链接: $shortcut_link${NC}"
    else
      log_message ERROR "删除快捷方式链接失败: $shortcut_link"
      echo -e "${RED}错误: 删除快捷方式链接失败: $shortcut_link${NC}"
    fi
  fi
  
  # 提示删除配置文件
  read -p "您想删除所有配置文件 ($CONFIG_DIR) 吗？ [y/N]: " delete_config_choice
  if [[ "${delete_config_choice,,}" =~ ^y$ ]]; then
    log_message INFO "正在删除配置目录: $CONFIG_DIR"
    if rm -rf "$CONFIG_DIR"; then
      echo -e "${GREEN}配置文件已删除。${NC}"
    else
      log_message ERROR "删除配置目录失败: $CONFIG_DIR"
      echo -e "${RED}错误: 删除配置目录失败: $CONFIG_DIR${NC}"
    fi
  else
    echo -e "${YELLOW}配置文件保留在 $CONFIG_DIR 中。${NC}"
    log_message INFO "配置文件已保留。"
  fi
  
  # 提示删除数据文件
  read -p "您想删除所有数据文件 ($DATA_DIR) 吗？ [y/N]: " delete_data_choice
  if [[ "${delete_data_choice,,}" =~ ^y$ ]]; then
    log_message INFO "正在删除数据目录: $DATA_DIR"
    if rm -rf "$DATA_DIR"; then
      echo -e "${GREEN}数据文件已删除。${NC}"
    else
      log_message ERROR "删除数据目录失败: $DATA_DIR"
      echo -e "${RED}错误: 删除数据目录失败: $DATA_DIR${NC}"
    fi
  else
    echo -e "${YELLOW}数据文件保留在 $DATA_DIR 中。${NC}"
    log_message INFO "数据文件已保留。"
  fi
  
  # 提示删除日志文件
  read -p "您想删除日志文件 ($LOG_FILE) 吗？ [y/N]: " delete_log_choice
  if [[ "${delete_log_choice,,}" =~ ^y$ ]]; then
    log_message INFO "正在删除日志文件: $LOG_FILE"
    if rm -f "$LOG_FILE"; then
      echo -e "${GREEN}日志文件已删除。${NC}"
    else
      log_message ERROR "删除日志文件失败: $LOG_FILE"
      echo -e "${RED}错误: 删除日志文件失败: $LOG_FILE${NC}"
    fi
  else
    echo -e "${YELLOW}日志文件保留在 $LOG_FILE 中。${NC}"
    log_message INFO "日志文件已保留。"
  fi
  
  # 提示删除脚本本身
  read -p "您想删除此脚本文件吗？ [y/N]: " delete_script_choice
  if [[ "${delete_script_choice,,}" =~ ^y$ ]]; then
    local script_self="$(realpath "$0")"
    log_message INFO "正在删除脚本本身: $script_self"
    echo -e "${BLUE}正在删除脚本本身...${NC}"
    if rm -f "$script_self"; then
      echo -e "${GREEN}脚本已删除。${NC}"
      log_message SUCCESS "DDNS 卸载完成，脚本已删除。"
      exit 0 # 自我删除后立即退出
    else
      log_message ERROR "删除脚本本身失败: $script_self"
      echo -e "${RED}错误: 删除脚本本身失败: $script_self${NC}"
    fi
  else
    echo -e "${YELLOW}脚本文件保留: $(realpath "$0")${NC}"
    log_message INFO "脚本文件已保留。"
  fi
  
  echo -e "${GREEN}DDNS 卸载完成。${NC}"
  log_message INFO "DDNS 卸载过程完成。"
}

# =====================================================================
# 核心 DDNS 逻辑函数
# =====================================================================

# 函数：发送 Telegram 通知
send_tg_notification() {
  local message="$1"
  
  if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    log_message INFO "未配置 Telegram 通知，跳过。"
    return 0
  fi
  
  # 使用 --silent 和 --show-error 以更好地控制 curl 输出。
  # 使用 -m 10 设置 10 秒超时。
  local response=$(curl -s --show-error -m 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=Markdown")
  
  if [[ "$response" == *"\"ok\":true"* ]]; then
    log_message INFO "Telegram 通知发送成功。"
    return 0
  else
    log_message ERROR "Telegram 通知失败: $response"
    return 1
  fi
}

# 函数：获取当前公网 IP 地址 (多源冗余)
get_wan_ip() {
  local record_type=$1
  local ip_sources=()
  local ip=""
  
  if [[ "$record_type" == "A" ]]; then
    ip_sources=("${WANIPSITE_v4[@]}")
  else # AAAA
    ip_sources=("${WANIPSITE_v6[@]}")
  fi
  
  for source in "${ip_sources[@]}"; do
    log_message INFO "正在尝试从 $source 获取 $record_type IP..."
    # 使用 -4 或 -6 与 curl 明确请求 IPv4 或 IPv6，并使用 -m 进行超时
    local curl_flags=""
    if [[ "$record_type" == "A" ]]; then curl_flags="-4"; else curl_flags="-6"; fi
    
    ip=$(curl -s --show-error -m 5 "$curl_flags" "$source" | tr -d '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([a-f0-9]{1,4}:){7}[a-f0-9]{1,4}')
    
    if [[ -n "$ip" ]]; then
      log_message INFO "成功从 $source 获取到 $record_type IP: $ip"
      echo "$ip"
      return 0
    fi
  done
  
  log_message ERROR "未能从所有来源获取 $record_type IP。"
  
  # 发送 Telegram 失败通知
  local message="❌ *Cloudflare DDNS 错误* 🔍 获取公网 IP 地址失败!
  记录类型: \`$record_type\`
  域名: \`$CFRECORD_NAME\`
  时间: $(date +"%Y-%m-%d %H:%M:%S %Z")
  ⚠️ 请检查网络连接或 IP 检测服务。"
  
  send_tg_notification "$message"
  
  return 1
}

# 函数：更新 DNS 记录 (带重试和自动创建)
update_record() {
  local record_type=$1
  local record_name=$2
  local wan_ip=$3
  local retries=3
  local delay=5 # 秒
  
  # ID 存储文件名 (按记录类型区分)
  local id_file="$DATA_DIR/.cf-id_${record_name//./_}_${record_type}.txt" # 替换点号以获取有效文件名
  local id_zone=""
  local id_record=""
  
  # 如果文件存在，则加载现有 ID
  if [[ -f "$id_file" ]]; then
    id_zone=$(head -1 "$id_file" 2>/dev/null)
    id_record=$(sed -n '2p' "$id_file" 2>/dev/null)
    log_message INFO "已加载 $record_name ($record_type) 的现有 ID: 区域 ID=$id_zone, 记录 ID=$id_record"
  else
    log_message INFO "找不到 $record_name ($record_type) 的 ID 存储文件。将尝试获取/创建 ID。"
  fi
  
  # --- 获取区域 ID ---
  if [ -z "$id_zone" ]; then
    log_message INFO "正在获取 $CFZONE_NAME 的区域 ID..."
    for ((i=1; i<=retries; i++)); do
      local zone_response=$(curl -s --show-error -m 10 -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json")
      
      id_zone=$(echo "$zone_response" | jq -r '.result[] | select(.name == "'"$CFZONE_NAME"'") | .id' 2>/dev/null) # 使用 jq 进行健壮解析
      
      if [ -n "$id_zone" ]; then
        log_message INFO "成功获取区域 ID: $id_zone"
        break
      else
        log_message WARN "获取 $CFZONE_NAME 的区域 ID 失败 (尝试 $i/$retries)。响应: $zone_response"
        sleep "$delay"
      fi
    done
    
    if [ -z "$id_zone" ]; then
      log_message ERROR "在 $retries 次尝试后未能获取区域 ID。正在退出 $record_type 的更新。"
      local message="❌ *Cloudflare DDNS 错误* 🔍 获取 \`$CFZONE_NAME\` 的区域 ID 失败!
      记录类型: \`$record_type\`
      时间: $(date +"%Y-%m-%d %H:%M:%S %Z")
      ⚠️ 请检查您的 CFZONE_NAME 和 API 凭据。"
      send_tg_notification "$message"
      return 1
    fi
  fi
  
  # --- 获取记录 ID ---
  if [ -z "$id_record" ]; then
    log_message INFO "正在获取区域 $id_zone 中 $record_name ($record_type) 的记录 ID..."
    for ((i=1; i<=retries; i++)); do
      local record_response=$(curl -s --show-error -m 10 -X GET "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records?name=$record_name&type=$record_type" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json")
      
      id_record=$(echo "$record_response" | jq -r '.result[] | select(.type == "'"$record_type"'") | .id' 2>/dev/null) # 使用 jq 进行健壮解析
      
      if [ -n "$id_record" ]; then
        log_message INFO "成功获取 $record_name ($record_type) 的记录 ID: $id_record。"
        break
      else
        log_message WARN "获取 $record_name ($record_type) 的记录 ID 失败 (尝试 $i/$retries)。响应: $record_response"
        sleep "$delay"
      fi
    done
  fi
  
  # --- 如果找不到记录，则创建记录 ---
  if [ -z "$id_record" ]; then
    log_message INFO "找不到 $record_name ($record_type) 的记录。正在创建新记录..."
    
    for ((i=1; i<=retries; i++)); do
      local create_response=$(curl -s --show-error -m 10 -X POST "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$wan_ip\", \"ttl\":$CFTTL,\"proxied\":false}") # 添加 proxied:false 作为 DDNS 的常见默认值
      
      if echo "$create_response" | grep -q "\"success\":true"; then
        id_record=$(echo "$create_response" | jq -r '.result.id' 2>/dev/null)
        if [ -n "$id_record" ]; then
          log_message SUCCESS "成功为 $record_name 创建了 $record_type 记录。记录 ID: $id_record"
          break
        else
          log_message ERROR "已创建记录，但无法从响应中解析 ID: $create_response"
        fi
      else
        log_message ERROR "创建 $record_name ($record_type) 记录失败 (尝试 $i/$retries)。API 响应: $create_response"
      fi
      sleep "$delay"
    done
    
    if [ -z "$id_record" ]; then
      log_message ERROR "在 $retries 次尝试后未能创建 $record_name 的新 $record_type 记录。正在中止更新。"
      local message="❌ *Cloudflare DDNS 创建失败* 🔍 未能为 \`$record_name\` (\`$record_type\` 类型) 创建记录!
      时间: $(date +"%Y-%m-%d %H:%M:%S %Z")
      ⚠️ 请检查 API 权限和 Cloudflare 上的现有记录。"
      send_tg_notification "$message"
      return 1
    fi
  fi
  
  # 将区域 ID 和记录 ID 保存到文件以备将来使用
  printf "%s\n%s" "$id_zone" "$id_record" > "$id_file"
  log_message INFO "区域 ID 和记录 ID 已保存到 $id_file。"
  
  # --- 更新 DNS 记录 ---
  log_message INFO "正在将 $record_name 的 $record_type 记录更新为 $wan_ip..."
  for ((i=1; i<=retries; i++)); do
    local update_response=$(curl -s --show-error -m 10 -X PUT "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records/$id_record" \
      -H "X-Auth-Email: $CFUSER" \
      -H "X-Auth-Key: $CFKEY" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$wan_ip\", \"ttl\":$CFTTL,\"proxied\":false}")
    
    if echo "$update_response" | grep -q "\"success\":true"; then
      log_message SUCCESS "成功将 $record_name 的 $record_type 记录更新为 $wan_ip。"
      return 0
    else
      log_message ERROR "更新 $record_name 的 $record_type 记录失败 (尝试 $i/$retries)。API 响应: $update_response"
      sleep "$delay"
    fi
  done
  
  # 如果所有重试后更新失败
  log_message ERROR "在 $retries 次尝试后更新 $record_type 记录失败，针对 $record_name。上次已知 IP: $wan_ip"
  local message="❌ *Cloudflare DDNS 更新失败* 🔍 记录类型: \`$record_type\`
  域名: \`$record_name\`
  新 IP (尝试): \`$wan_ip\`
  尝试次数: $retries
  时间: $(date +"%Y-%m-%d %H:%M:%S %Z")
  ⚠️ 请检查 API 权限和 Cloudflare 状态。"
  send_tg_notification "$message"
  
  return 1
}
 
# =====================================================================
# 函数：处理单一记录类型 (A 或 AAAA) 的更新
# =====================================================================
process_record_type() {
  local record_type=$1
  local ip_file="$DATA_DIR/.cf-wan_ip_${CFRECORD_NAME//./_}_${record_type}.txt"
  local current_ip=""
  local old_ip=""
  
  log_message INFO "正在处理 $CFRECORD_NAME 的 $record_type 记录。"
  
  # 获取当前公网 IP
  if ! current_ip=$(get_wan_ip "$record_type"); then
    log_message ERROR "未能获取当前 $record_type IP。跳过此类型的更新。"
    return 1
  fi
  
  # 读取上次存储的 IP
  if [[ -f "$ip_file" ]]; then
    old_ip=$(cat "$ip_file")
  fi
  
  # 检查是否需要更新 (IP 已更改或 FORCE 为 true)
  if [[ "$current_ip" != "$old_ip" ]] || [[ "$FORCE" == "true" ]]; then
    log_message INFO "$record_type IP 已从 '${old_ip:-无}' 更改为 '$current_ip' 或强制更新已启用。"
    
    if update_record "$record_type" "$CFRECORD_NAME" "$current_ip"; then
      echo "$current_ip" > "$ip_file" # 成功后保存新 IP
      log_message SUCCESS "$record_type IP 已成功更新并保存到 $ip_file。"
      
      # 发送成功通知
      local message="✅ *Cloudflare DDNS 更新成功* 记录类型: \`$record_type\`
      域名: \`$CFRECORD_NAME\`
      新 IP: \`$current_ip\`
      旧 IP: \`${old_ip:-无}\`
      时间: $(date +"%Y-%m-%d %H:%M:%S %Z")"
      send_tg_notification "$message"
    else
      log_message ERROR "更新 $record_type 记录失败。"
      return 1
    fi
  else
    log_message INFO "$record_type IP 地址未更改: $current_ip。无需更新。"
  fi
  return 0
}

# =====================================================================
# 函数：执行 DDNS 更新
# =====================================================================
run_ddns_update() {
  rotate_logs "$LOG_FILE" # 在开始更新前执行日志轮换
  
  log_message INFO "正在启动动态 DNS 更新过程。"
  
  # 加载配置
  if ! load_config; then
    log_message ERROR "找不到配置文件或配置不完整。无法运行 DDNS 更新。"
    local message="❌ *Cloudflare DDNS 错误* 🔍 找不到配置文件或配置不完整!
    时间: $(date +"%Y-%m-%d %H:%M:%S %Z")
    ⚠️ 请运行安装程序或修改配置。"
    send_tg_notification "$message"
    exit 1
  fi
  
  # 基本配置验证
  if [[ -z "$CFKEY" || -z "$CFUSER" || -z "$CFZONE_NAME" || -z "$CFRECORD_NAME" ]]; then
    log_message ERROR "缺少必要的 Cloudflare 配置参数。无法继续。"
    local message="❌ *Cloudflare DDNS 错误* 🔍 缺少必要的 Cloudflare 配置参数!
    时间: $(date +"%Y-%m-%d %H:%M:%S %Z")
    ⚠️ 请运行安装程序或修改配置。"
    send_tg_notification "$message"
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
      exit 2
      ;;
  esac
  
  if [ "$update_status_v4" -eq 0 ] && [ "$update_status_v6" -eq 0 ]; then
    log_message SUCCESS "动态 DNS 更新过程成功完成。"
  else
    log_message ERROR "动态 DNS 更新过程完成但有错误。"
  fi
}

# =====================================================================
# 函数：安装DDNS
# =====================================================================
install_ddns() {
  echo -e "${YELLOW}正在开始 DDNS 安装...${NC}"
  log_message INFO "正在启动 DDNS 安装。"
  
  init_dirs # 初始化目录
  
  # 运行配置向导
  interactive_config
  
  # 添加定时任务
  add_cron_job
  
  # 将脚本复制到系统路径
  echo -e "${BLUE}正在将脚本安装到系统路径...${NC}"
  local script_path=$(realpath "$0")
  local dest_path="/usr/local/bin/cf-ddns"
  
  if cp -f "$script_path" "$dest_path"; then
    chmod 755 "$dest_path"
    log_message SUCCESS "脚本已安装到 $dest_path。"
    echo -e "${GREEN}脚本已安装到系统路径: $dest_path${NC}"
  else
    log_message ERROR "将脚本复制到 $dest_path 失败。中止安装。"
    echo -e "${RED}错误: 将脚本复制到 $dest_path 失败。请检查权限。${NC}"
    exit 1
  fi
  
  # 添加快捷方式链接 'd'
  local shortcut_link="/usr/local/bin/d"
  if [ ! -f "$shortcut_link" ] && [ ! -L "$shortcut_link" ]; then # 确保链接不存在
    if ln -s "$dest_path" "$shortcut_link"; then
      echo -e "${GREEN}已创建快捷方式: 输入 'd' 即可启动脚本菜单。${NC}"
      log_message SUCCESS "已创建快捷方式链接 'd'。"
    else
      log_message WARN "创建快捷方式链接 'd' 失败。可能需要手动创建。"
      echo -e "${YELLOW}警告: 创建快捷方式链接 'd' 失败。您可以手动创建: ln -s $dest_path $shortcut_link${NC}"
    fi
  else
    log_message INFO "快捷方式链接 'd' 已存在，跳过创建。"
    echo -e "${YELLOW}快捷方式 'd' 已存在。${NC}"
  fi
  
  # 立即运行首次更新
  echo -e "${GREEN}正在运行首次更新...${NC}"
  run_ddns_update
  echo -e "${GREEN}首次更新完成! 请查看日志以获取详细信息。${NC}"
  
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${BLUE}           安装完成!                          ${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "您现在可以使用以下命令:"
  echo -e "  - 输入 '${GREEN}d${NC}' 快速启动管理菜单。"
  echo -e "  - 输入 '${GREEN}cf-ddns${NC}' 启动管理菜单。"
  echo -e "  - 输入 '${GREEN}cf-ddns update${NC}' 手动更新 DNS 记录。"
  echo -e "  - 查看日志路径: ${BLUE}$LOG_FILE${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  log_message INFO "DDNS 安装过程完成。"
}

# =====================================================================
# 函数：修改配置
# =====================================================================
modify_config() {
  echo -e "${YELLOW}正在开始配置修改...${NC}"
  log_message INFO "正在启动配置修改。"
  
  # 首先加载现有配置
  if ! load_config; then
    echo -e "${RED}错误: 未找到现有配置。${NC}"
    echo -e "请先运行选项 1 (安装和配置 DDNS)。"
    log_message ERROR "尝试修改配置，但未找到现有配置。"
    return 1
  fi
  
  # 备份旧配置
  local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  if cp "$CONFIG_FILE" "$backup_file"; then
    echo -e "${BLUE}旧配置已备份到: $backup_file${NC}"
    log_message INFO "配置已备份到 $backup_file。"
  else
    log_message WARN "备份旧配置失败。继续进行。"
    echo -e "${YELLOW}警告: 备份旧配置失败。请检查权限。${NC}"
  fi
  
  show_current_config # 修改前显示当前配置
  
  interactive_config # 运行交互式向导以获取新设置
  
  add_cron_job # 重新添加/更新定时任务，以防脚本路径更改或其他更新
  
  echo -e "${GREEN}配置修改完成!${NC}"
  log_message INFO "配置修改过程完成。"
}

# =====================================================================
# 函数：显示当前配置
# =====================================================================
show_current_config() {
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${BLUE}          当前 DDNS 配置                      ${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  if load_config; then
    echo "API 密钥       : ${CFKEY:0:4}****${CFKEY: -4}"
    echo "账户邮箱       : $CFUSER"
    echo "域名区域       : $CFZONE_NAME"
    echo "主机记录       : $CFRECORD_NAME"
    echo "记录类型       : $CFRECORD_TYPE"
    echo "TTL 值         : $CFTTL 秒"
    echo "强制更新       : $FORCE"
    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
      echo "Telegram 通知: 已启用"
      echo "  机器人 Token: ${TG_BOT_TOKEN:0:4}****${TG_BOT_TOKEN: -4}"
      echo "  聊天 ID     : $TG_CHAT_ID"
    else
      echo "Telegram 通知: 已禁用"
    fi
    echo "----------------------------------------"
  else
    echo -e "${RED}未找到有效配置。请先安装 DDNS。${NC}"
  fi
  echo -e "${YELLOW}==============================================${NC}"
}

# 函数：查看日志
view_logs() {
  if [ -f "$LOG_FILE" ]; then
    echo -e "${YELLOW}显示日志的最后 20 行:${NC}"
    echo "----------------------------------------"
    tail -n 20 "$LOG_FILE"
    echo "----------------------------------------"
    echo -e "完整日志路径: ${BLUE}$LOG_FILE${NC}"
    read -p "按回车键查看更多，或输入 'q' 退出 (使用 less): " view_more
    if [[ "${view_more,,}" != "q" ]]; then
        less "$LOG_FILE"
    fi
  else
    echo -e "${RED}未找到日志文件: $LOG_FILE${NC}"
  fi
}

# =====================================================================
# 主程序入口
# =====================================================================

# 确保必要的工具可用
check_dependencies() {
  local dependencies=("curl" "grep" "sed" "jq") # 添加了 jq 用于健壮的 JSON 解析
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      echo -e "${RED}错误: 找不到所需的命令 '$dep'。${NC}" >&2
      echo -e "${RED}请安装它 (例如：sudo apt-get install $dep 或 sudo yum install $dep)。${NC}" >&2
      exit 1
    fi
  done
}

# 初始检查
check_dependencies
init_dirs # 确保在任何日志记录发生之前目录和日志文件存在
rotate_logs "$LOG_FILE" # 在脚本开始时执行日志轮换

# 检查是否以 root 运行
if [ "$(id -u)" -ne 0 ]; then
  log_message ERROR "此脚本需要 root 权限运行。"
  echo -e "${RED}错误: 此脚本需要 root 权限运行。${NC}"
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
      echo -e "${RED}无效参数: $1${NC}"
      echo "用法: $(basename "$0") [update|install|modify|uninstall]"
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
      read -p "按回车键返回主菜单..."
      ;;
    2)
      modify_config
      read -p "按回车键返回主菜单..."
      ;;
    3)
      uninstall_ddns
      read -p "按回车键返回主菜单..." # 如果脚本自我删除，此提示可能不会被触及
      ;;
    4)
      show_current_config
      read -p "按回车键返回主菜单..."
      ;;
    5)
      echo -e "${YELLOW}正在手动运行更新...${NC}"
      log_message INFO "从菜单手动触发更新。"
      run_ddns_update
      echo -e "${GREEN}更新完成! 请查看日志以获取详细信息。${NC}"
      read -p "按回车键返回主菜单..."
      ;;
    6)
      view_logs
      read -p "按回车键返回主菜单..."
      ;;
    7)
      configure_telegram
      read -p "按回车键返回主菜单..."
      ;;  
    8)
      log_message INFO "从菜单退出脚本。"
      echo -e "${GREEN}正在退出脚本。${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}无效选项，请重新输入。${NC}"
      sleep 2
      ;;
  esac
done
