#!/usr/bin/env bash
# Cloudflare DDNS 管理脚本 (模块化配置最终版 - 优化后)

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
DEFAULT_CRON_SCHEDULE="*/2 * * * *" # 默认定时任务频率 (每2分钟)

# --- 默认配置参数 (将被配置文件覆盖，并确保有初始值) ---
CFKEY=""               # Cloudflare API 密钥
CFUSER=""              # Cloudflare 账户邮箱
CFZONE_NAME=""         # 域名区域 (例如：example.com)
CFTTL=120              # DNS 记录 TTL 值 (120-86400 秒)
FORCE=false            # 强制更新模式 (忽略本地 IP 缓存)
ENABLE_IPV4=true       # 是否启用 IPv4 (A 记录) 更新
CFRECORD_NAME_V4=""    # IPv4 的完整记录名称 (例如：ipv4.example.com)
ENABLE_IPV6=true       # 是否启用 IPv6 (AAAA 记录) 更新
CFRECORD_NAME_V6=""    # IPv6 的完整记录名称 (例如：ipv6.example.com)
TG_BOT_TOKEN=""        # Telegram 机器人 Token
TG_CHAT_ID=""          # Telegram 聊天 ID

# --- 公网 IP 检测服务 (多源冗余) ---
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
  
  # 写入日志文件时，不带颜色码，以免文件内容混乱
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 

  local level_color="${NC}"
  case "$level" in
    "INFO") level_color="${BLUE}" ;;
    "WARN") level_color="${YELLOW}" ;;
    "ERROR") level_color="${RED}" ;;
    "SUCCESS") level_color="${GREEN}" ;;
  esac
  # 仅在标准错误输出中显示颜色 (方便用户在终端中查看)
  echo -e "${level_color}$(date +"%H:%M:%S") [$level] $message${NC}" >&2
}

# 函数：显示主菜单
show_main_menu() {
  clear
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${BLUE}     🚀 CloudFlare DDNS 管理脚本 (模块化配置版) 🚀     ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${GREEN} 1. ✨ 安装并配置 DDNS${NC}"
  echo -e "${GREEN} 2. ⚙️ 修改 DDNS 配置${NC}"
  echo -e "${GREEN} 3. 📋 查看当前配置${NC}"
  echo -e "${GREEN} 4. ⚡ 手动运行更新${NC}"
  echo -e "${GREEN} 5. ⏱️ 定时任务管理${NC}" # 新增定时任务管理
  echo -e "${GREEN} 6. 📜 查看日志${NC}"
  echo -e "${GREEN} 7. 🗑️ 卸载 DDNS${NC}"
  echo -e "${GREEN} 8. 🚪 退出脚本${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo
  read -p "$(echo -e "${PURPLE}请选择一个操作 [1-8]: ${NC}")" main_choice
}

# 函数：初始化目录结构
init_dirs() {
  log_message INFO "正在初始化目录..."
  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  chmod 700 "$CONFIG_DIR" "$DATA_DIR"
  
  # 确保日志文件存在并设置正确权限
  if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    log_message INFO "日志文件 '$LOG_FILE' 已创建。"
  else
    chmod 600 "$LOG_FILE" # 确保权限始终正确
  fi
  log_message INFO "目录初始化完成。"
}

# 函数：轮换日志
# 策略：每天运行一次时，将前一天的日志归档，并保留最近 7 天的归档。
# 此函数应通过独立的 cron job 调用，而不是每次 DDNS 更新时调用。
rotate_logs() {
  local log_file="$1"
  local log_dir=$(dirname "$log_file")
  local log_base=$(basename "$log_file")
  local max_archives=7 # 保留最近 7 天的日志归档

  log_message INFO "检查日志轮换: $log_file"

  # 如果日志文件存在且非空
  if [ -s "$log_file" ]; then
    local yesterday=$(date -d "yesterday" +%Y-%m-%d)
    local archive_file="${log_dir}/${log_base}.${yesterday}"

    # 检查是否已经存在今天的归档 (防止重复归档)
    local today_archive="${log_dir}/${log_base}.$(date +%Y-%m-%d)"
    if [ -f "$today_archive" ]; then
      log_message INFO "今天的日志 '$today_archive' 已归档，跳过当前归档操作。"
    else
      # 将当前日志文件重命名为昨天的归档文件
      if mv "$log_file" "$archive_file"; then
        log_message SUCCESS "日志文件已归档到: $archive_file"
        # 创建新的空日志文件并设置权限
        if ! touch "$log_file" || ! chmod 600 "$log_file"; then
          log_message ERROR "未能创建新的日志文件 '$log_file' 或设置权限。"
        fi
      else
        log_message ERROR "未能归档日志文件 '$log_file'。请检查权限。"
      fi
    fi
  elif [ ! -f "$log_file" ]; then
    log_message INFO "日志文件 '$log_file' 不存在，无需归档。正在创建新文件..."
    if ! touch "$log_file" || ! chmod 600 "$log_file"; then
        log_message ERROR "未能创建新的日志文件 '$log_file' 或设置权限。"
    fi
  else # 文件存在但为空
    log_message INFO "日志文件 '$log_file' 为空，无需归档。"
  fi

  # 清理旧的归档文件
  log_message INFO "正在清理超过 $max_archives 天的旧日志归档..."
  find "$log_dir" -name "${log_base}.*" -type f -mtime +"$max_archives" -delete
  log_message SUCCESS "旧日志归档清理完成。"
}

# =====================================================================
# 配置功能模块 (核心重构部分)
# =====================================================================

# --- 基础配置模块 ---
configure_base() {
  echo -e "\n${CYAN}--- 1. 修改基础配置 ---${NC}"
  
  local new_key new_user new_zone
  read -p "$(echo -e "${PURPLE}请输入 Cloudflare API 密钥 (当前: ${CFKEY:0:4}****${CFKEY: -4}, 直接回车保留): ${NC}")" new_key
  CFKEY=${new_key:-$CFKEY}
  while ! [[ "$CFKEY" =~ ^[a-zA-Z0-9]{37}$ ]]; do
    echo -e "${RED}❌ 错误: API 密钥格式无效。${NC}"; read -p "$(echo -e "${PURPLE}请重新输入: ${NC}")" CFKEY
  done
  echo -e "${GREEN}✅ API 密钥已更新。${NC}\n"

  read -p "$(echo -e "${PURPLE}请输入 Cloudflare 账户邮箱 (当前: $CFUSER, 直接回车保留): ${NC}")" new_user
  CFUSER=${new_user:-$CFUSER}
  while ! [[ "$CFUSER" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    echo -e "${RED}❌ 错误: 邮箱格式无效。${NC}"; read -p "$(echo -e "${PURPLE}请重新输入: ${NC}")" CFUSER
  done
  echo -e "${GREEN}✅ 邮箱已更新。${NC}\n"

  read -p "$(echo -e "${PURPLE}请输入您的主域名 (当前: $CFZONE_NAME, 直接回车保留): ${NC}")" new_zone
  CFZONE_NAME=${new_zone:-$CFZONE_NAME}
  while ! [[ "$CFZONE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    echo -e "${RED}❌ 错误: 域名格式无效。${NC}"; read -p "$(echo -e "${PURPLE}请重新输入: ${NC}")" CFZONE_NAME
  done
  echo -e "${GREEN}✅ 域名区域已更新。${NC}\n"
}

# --- IPv4 配置模块 ---
configure_ipv4() {
  echo -e "\n${CYAN}--- 2. 修改 IPv4 (A 记录) 配置 ---${NC}"
  local current_status="n" && [[ "$ENABLE_IPV4" == "true" ]] && current_status="Y"
  read -p "$(echo -e "${PURPLE}是否启用 IPv4 DDNS 解析? [Y/n] (当前: ${current_status}): ${NC}")" enable_v4
  enable_v4=${enable_v4:-$current_status}

  if [[ ! "${enable_v4,,}" =~ ^n$ ]]; then
    ENABLE_IPV4=true
    echo -e "${GREEN}✅ 已启用 IPv4 解析。${NC}"
    
    local current_record_v4=""
    if [[ -n "$CFRECORD_NAME_V4" && -n "$CFZONE_NAME" && "$CFRECORD_NAME_V4" == *"$CFZONE_NAME"* ]]; then
      current_record_v4=${CFRECORD_NAME_V4%.$CFZONE_NAME}
      if [[ "$current_record_v4" == "$CFRECORD_NAME_V4" ]]; then current_record_v4="@"; fi # 主域名的情况
    fi

    read -p "$(echo -e "${PURPLE}请输入用于 IPv4 的主机记录 (当前: ${current_record_v4}, 直接回车保留): ${NC}")" record_name_v4_input
    record_name_v4_input=${record_name_v4_input:-$current_record_v4}
    
    if [ -n "$record_name_v4_input" ]; then
      # 增强主机记录验证
      if ! [[ "$record_name_v4_input" =~ ^[a-zA-Z0-9.-_@]+$ ]]; then
        echo -e "${RED}❌ 错误: 主机记录包含无效字符! 请只使用字母、数字、点、横线、下划线或 '@'。保留原值。${NC}"
        return 1
      fi

      if [[ "$record_name_v4_input" == "@" ]]; then CFRECORD_NAME_V4="$CFZONE_NAME"; else CFRECORD_NAME_V4="${record_name_v4_input}.${CFZONE_NAME}"; fi
      echo -e "${GREEN}💡 IPv4 完整域名已更新为: ${CFRECORD_NAME_V4}${NC}"
    else
      echo -e "${RED}❌ 错误: 主机记录不能为空! 保留原值。${NC}"
    fi
  else
    ENABLE_IPV4=false
    CFRECORD_NAME_V4=""
    echo -e "${YELLOW}ℹ️ 已禁用 IPv4 解析。${NC}"
  fi
}

# --- IPv6 配置模块 ---
configure_ipv6() {
  echo -e "\n${CYAN}--- 3. 修改 IPv6 (AAAA 记录) 配置 ---${NC}"
  local current_status="n" && [[ "$ENABLE_IPV6" == "true" ]] && current_status="Y"
  read -p "$(echo -e "${PURPLE}是否启用 IPv6 DDNS 解析? [Y/n] (当前: ${current_status}): ${NC}")" enable_v6
  enable_v6=${enable_v6:-$current_status}

  if [[ ! "${enable_v6,,}" =~ ^n$ ]]; then
    ENABLE_IPV6=true
    echo -e "${GREEN}✅ 已启用 IPv6 解析。${NC}"

    local current_record_v6=""
    if [[ -n "$CFRECORD_NAME_V6" && -n "$CFZONE_NAME" && "$CFRECORD_NAME_V6" == *"$CFZONE_NAME"* ]]; then
      current_record_v6=${CFRECORD_NAME_V6%.$CFZONE_NAME}
      if [[ "$current_record_v6" == "$CFRECORD_NAME_V6" ]]; then current_record_v6="@"; fi # 主域名的情况
    fi

    read -p "$(echo -e "${PURPLE}请输入用于 IPv6 的主机记录 (例如: ${CYAN}ipv6${PURPLE}, ${CYAN}@${PURPLE} 表示主域名本身)。${NC}")" record_name_v6_input
    record_name_v6_input=${record_name_v6_input:-$current_record_v6}

    if [ -n "$record_name_v6_input" ]; then
      # 增强主机记录验证
      if ! [[ "$record_name_v6_input" =~ ^[a-zA-Z0-9.-_@]+$ ]]; then
        echo -e "${RED}❌ 错误: 主机记录包含无效字符! 请只使用字母、数字、点、横线、下划线或 '@'。保留原值。${NC}"
        return 1
      fi

      if [[ "$record_name_v6_input" == "@" ]]; then CFRECORD_NAME_V6="$CFZONE_NAME"; else CFRECORD_NAME_V6="${record_name_v6_input}.${CFZONE_NAME}"; fi
      echo -e "${GREEN}💡 IPv6 完整域名已更新为: ${CFRECORD_NAME_V6}${NC}"
    else
      echo -e "${RED}❌ 错误: 主机记录不能为空! 保留原值。${NC}"
    fi
  else
    ENABLE_IPV6=false
    CFRECORD_NAME_V6=""
    echo -e "${YELLOW}ℹ️ 已禁用 IPv6 解析。${NC}"
  fi
}

# --- Telegram 配置函数 (修改为可独立调用和在向导中调用) ---
configure_telegram() {
  echo -e "\n${CYAN}--- 🔔 配置 Telegram 通知详情 🔔 ---${NC}"
  echo -e "${YELLOW}为了接收通知，您需要一个 Telegram Bot Token 和您的 Chat ID。${NC}"
  echo -e "${BLUE}获取方式:${NC}"
  echo -e "  ${PURPLE}1. 在 Telegram 搜索并与 ${CYAN}@BotFather${PURPLE} 聊天。${NC}"
  echo -e "  ${PURPLE}2. 发送 ${CYAN}/newbot${PURPLE} 创建一个新机器人，它会给您一个 Token。${NC}"
  echo -e "  ${PURPLE}3. 搜索并与 ${CYAN}@userinfobot${PURPLE} 聊天，发送 ${CYAN}/start${PURPLE} 获取您的 Chat ID。${NC}\n"
  
  read -p "$(echo -e "${PURPLE}请输入 Telegram Bot Token (当前: ${TG_BOT_TOKEN:0:10}..., 直接回车保留): ${NC}")" new_token
  TG_BOT_TOKEN=${new_token:-$TG_BOT_TOKEN}
  while ! [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; do
    echo -e "${RED}❌ 错误: Token 格式无效! 请确保是 '数字:字母数字' 格式。${NC}"; read -p "$(echo -e "${PURPLE}请重新输入 Bot Token: ${NC}")" TG_BOT_TOKEN
  done

  read -p "$(echo -e "${PURPLE}请输入 Telegram Chat ID (当前: $TG_CHAT_ID, 直接回车保留): ${NC}")" new_chat_id
  TG_CHAT_ID=${new_chat_id:-$TG_CHAT_ID}
  while ! [[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]]; do
    echo -e "${RED}❌ 错误: Chat ID 必须是数字!${NC}"; read -p "$(echo -e "${PURPLE}请重新输入 Chat ID: ${NC}")" TG_CHAT_ID
  done
  
  echo -e "${YELLOW}----------------------------------------------${NC}"
  log_message INFO "正在发送 Telegram 测试消息..."
  echo -e "${BLUE}➡️ 正在尝试发送测试消息到您的 Telegram...${NC}"

  local domains_for_test=""
  if [[ "$ENABLE_IPV4" == "true" && -n "$CFRECORD_NAME_V4" ]]; then
      domains_for_test+="IPv4: \`${CFRECORD_NAME_V4}\`"
  fi
  if [[ "$ENABLE_IPV6" == "true" && -n "$CFRECORD_NAME_V6" ]]; then
      if [[ -n "$domains_for_test" ]]; then
          domains_for_test+=$'\n'
      fi
      domains_for_test+="IPv6: \`${CFRECORD_NAME_V6}\`"
  fi

  if send_tg_notification "🔔 *Cloudflare DDNS 通知* 🔔

*配置测试成功!* ✅
已配置域名:
${domains_for_test}
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

一切就绪! ✨"; then
    echo -e "${GREEN}✅ 测试消息发送成功! 请检查您的 Telegram 消息。${NC}"
  else
    echo -e "${RED}❌ 测试消息发送失败! 请检查您的 Token 和 Chat ID 是否正确。${NC}"
  fi
  
  return 0
}

# --- TTL 配置模块 ---
configure_ttl() {
  echo -e "\n${CYAN}--- 5. 修改 TTL 值 ---${NC}"
  read -p "$(echo -e "${PURPLE}请输入 DNS 记录的 TTL 值 (120-86400 秒, 当前: $CFTTL, 直接回车保留): ${NC}")" ttl_input
  ttl_input=${ttl_input:-$CFTTL}
  if [[ "$ttl_input" =~ ^[0-9]+$ ]] && [ "$ttl_input" -ge 120 ] && [ "$ttl_input" -le 86400 ]; then
    CFTTL="$ttl_input"
    echo -e "${GREEN}✅ TTL 值已更新为: ${CFTTL} 秒。${NC}"
  else
    echo -e "${RED}❌ 错误: TTL 值无效! 保留原值: $CFTTL。${NC}"
  fi
}

# --- 完整的配置向导（用于首次安装） ---
run_full_config_wizard() {
  clear
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${BLUE}      ✨ CloudFlare DDNS 首次配置向导 ✨         ${NC}"
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${YELLOW}欢迎使用 CloudFlare DDNS 配置向导！${NC}"
  echo -e "${YELLOW}请按照提示输入您的配置信息，我们将引导您完成设置。${NC}"
  echo -e "${YELLOW}在首次配置时，所有字段都是必填的。${NC}\n" # 明确首次配置时都是必填的

  # 基础配置
  echo -e "${GREEN}--- 步骤 1/5: Cloudflare 账户信息 ---${NC}" # 步骤数更改
  echo -e "${PURPLE}请提供您的 Cloudflare API 密钥、账户邮箱和主域名。${NC}"
  echo -e "${PURPLE}API 密钥可在 Cloudflare 个人资料的 'API 令牌' 页面找到 (Global API Key)。${NC}"
  read -p "$(echo -e "${PURPLE}请输入 Cloudflare API 密钥: ${NC}")" CFKEY
  while ! [[ "$CFKEY" =~ ^[a-zA-Z0-9]{37}$ ]]; do
    echo -e "${RED}❌ 错误: API 密钥格式无效。请检查您的密钥是否为 37 位字符。${NC}"
    read -p "$(echo -e "${PURPLE}请重新输入 Cloudflare API 密钥: ${NC}")" CFKEY
  done
  echo -e "${GREEN}✅ API 密钥已设置。${NC}\n"

  read -p "$(echo -e "${PURPLE}请输入您的 Cloudflare 账户注册邮箱地址 (例如: your_email@example.com): ${NC}")" CFUSER
  while ! [[ "$CFUSER" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    echo -e "${RED}❌ 错误: 邮箱格式无效。请确保包含 '@' 和域名部分。${NC}"
    read -p "$(echo -e "${PURPLE}请重新输入 Cloudflare 账户邮箱: ${NC}")" CFUSER
  done
  echo -e "${GREEN}✅ 邮箱已设置。${NC}\n"

  echo -e "${PURPLE}请输入您希望管理 DNS 记录的主域名 (Zone Name)。${NC}"
  echo -e "${PURPLE}例如: ${CYAN}example.com${PURPLE} (不带 'www' 或 'http://' 等)。${NC}"
  read -p "$(echo -e "${PURPLE}请输入您的主域名: ${NC}")" CFZONE_NAME
  while ! [[ "$CFZONE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    echo -e "${RED}❌ 错误: 域名格式无效。请确保是有效的顶级域名，例如 example.com。${NC}"
    read -p "$(echo -e "${PURPLE}请重新输入主域名: ${NC}")" CFZONE_NAME
  done
  echo -e "${GREEN}✅ 主域名已设置。${NC}\n"

  # IPv4 配置
  echo -e "${GREEN}--- 步骤 2/5: IPv4 (A 记录) 配置 ---${NC}" # 步骤数更改
  echo -e "${PURPLE}您是否需要启用 IPv4 (A 记录) 的动态 DNS 解析?${NC}"
  read -p "$(echo -e "${PURPLE}是否启用 IPv4 解析? [Y/n]: ${NC}")" enable_v4_choice
  if [[ "${enable_v4_choice,,}" =~ ^n$ ]]; then
    ENABLE_IPV4=false
    CFRECORD_NAME_V4=""
    echo -e "${YELLOW}ℹ️ 已禁用 IPv4 解析。${NC}\n"
  else
    ENABLE_IPV4=true
    echo -e "${GREEN}✅ 已启用 IPv4 解析。${NC}"
    echo -e "${PURPLE}请输入用于 IPv4 的主机记录 (例如: ${CYAN}www${PURPLE}, ${CYAN}blog${PURPLE}, 使用 ${CYAN}@${PURPLE} 表示主域名本身)。${NC}"
    read -p "$(echo -e "${PURPLE}请输入 IPv4 主机记录: ${NC}")" record_name_v4_input
    while [ -z "$record_name_v4_input" ] || ! [[ "$record_name_v4_input" =~ ^[a-zA-Z0-9.-_@]+$ ]]; do # 增强验证
      if [ -z "$record_name_v4_input" ]; then
        echo -e "${RED}❌ 错误: 主机记录不能为空!${NC}"
      else
        echo -e "${RED}❌ 错误: 主机记录包含无效字符! 请只使用字母、数字、点、横线、下划线或 '@'。${NC}"
      fi
      read -p "$(echo -e "${PURPLE}请重新输入 IPv4 主机记录: ${NC}")" record_name_v4_input
    done
    if [[ "$record_name_v4_input" == "@" ]]; then CFRECORD_NAME_V4="$CFZONE_NAME"; else CFRECORD_NAME_V4="${record_name_v4_input}.${CFZONE_NAME}"; fi
    echo -e "${GREEN}💡 IPv4 完整域名将是: ${CFRECORD_NAME_V4}${NC}\n"
  fi

  # IPv6 配置
  echo -e "${GREEN}--- 步骤 3/5: IPv6 (AAAA 记录) 配置 ---${NC}" # 步骤数更改
  echo -e "${PURPLE}您是否需要启用 IPv6 (AAAA 记录) 的动态 DNS 解析?${NC}"
  read -p "$(echo -e "${PURPLE}是否启用 IPv6 解析? [Y/n]: ${NC}")" enable_v6_choice
  if [[ "${enable_v6_choice,,}" =~ ^n$ ]]; then
    ENABLE_IPV6=false
    CFRECORD_NAME_V6=""
    echo -e "${YELLOW}ℹ️ 已禁用 IPv6 解析。${NC}\n"
  else
    ENABLE_IPV6=true
    echo -e "${GREEN}✅ 已启用 IPv6 解析。${NC}"
    echo -e "${PURPLE}请输入用于 IPv6 的主机记录 (例如: ${CYAN}ipv6${PURPLE}, ${CYAN}@${PURPLE} 表示主域名本身)。${NC}"
    read -p "$(echo -e "${PURPLE}请输入 IPv6 主机记录: ${NC}")" record_name_v6_input
    while [ -z "$record_name_v6_input" ] || ! [[ "$record_name_v6_input" =~ ^[a-zA-Z0-9.-_@]+$ ]]; do # 增强验证
      if [ -z "$record_name_v6_input" ]; then
        echo -e "${RED}❌ 错误: 主机记录不能为空!${NC}"
      else
        echo -e "${RED}❌ 错误: 主机记录包含无效字符! 请只使用字母、数字、点、横线、下划线或 '@'。${NC}"
      fi
      read -p "$(echo -e "${PURPLE}请重新输入 IPv6 主机记录: ${NC}")" record_name_v6_input
    done
    if [[ "$record_name_v6_input" == "@" ]]; then CFRECORD_NAME_V6="$CFZONE_NAME"; else CFRECORD_NAME_V6="${record_name_v6_input}.${CFZONE_NAME}"; fi
    echo -e "${GREEN}💡 IPv6 完整域名将是: ${CFRECORD_NAME_V6}${NC}\n"
  fi

  # 强制检查至少启用一个
  if [[ "$ENABLE_IPV4" == "false" && "$ENABLE_IPV6" == "false" ]]; then
    log_message ERROR "IPv4 和 IPv6 解析不能同时禁用! 您必须至少启用一个解析类型。" # 日志记录
    echo -e "${RED}❌ 错误: IPv4 和 IPv6 解析不能同时禁用! 您必须至少启用一个解析类型。${NC}"
    read -p "按回车键重新配置，强制选择一个解析类型..."
    run_full_config_wizard # 递归调用以强制用户启用一个
    return
  fi

  # TTL 配置
  echo -e "${GREEN}--- 步骤 4/5: DNS 记录 TTL 配置 ---${NC}" # 步骤数更改
  echo -e "${PURPLE}TTL (Time To Live) 是 DNS 记录在客户端缓存中保留的时间。${NC}"
  echo -e "${PURPLE}较小的值 (如 ${CYAN}120${PURPLE} 秒) 意味着 IP 变化时更新更快，但可能增加 DNS 查询负载。${NC}"
  echo -e "${PURPLE}建议值在 ${CYAN}120${PURPLE} (2分钟) 到 ${CYAN}86400${PURPLE} (1天) 秒之间。${NC}"
  read -p "$(echo -e "${PURPLE}请输入 DNS 记录的 TTL 值 (默认: ${CFTTL} 秒): ${NC}")" ttl_input
  ttl_input=${ttl_input:-$CFTTL} # 如果用户直接回车，则使用默认值
  while ! ([[ "$ttl_input" =~ ^[0-9]+$ ]] && [ "$ttl_input" -ge 120 ] && [ "$ttl_input" -le 86400 ]); do
    log_message ERROR "TTL 值无效! 输入: '$ttl_input'。" # 日志记录
    echo -e "${RED}❌ 错误: TTL 值无效! 请输入一个 120 到 86400 之间的整数。${NC}"
    read -p "$(echo -e "${PURPLE}请重新输入 TTL 值: ${NC}")" ttl_input
  done
  CFTTL="$ttl_input"
  echo -e "${GREEN}✅ TTL 值已设置为: ${CFTTL} 秒。${NC}\n"

  # Telegram 配置 (集成到首次向导中)
  echo -e "${GREEN}--- 步骤 5/5: Telegram 通知配置 ---${NC}" # 步骤数更改
  configure_telegram_in_wizard_mode # 调用一个专门用于向导模式的Telegram配置函数
  
  # 配置完成
  save_config
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${GREEN}🎉 恭喜! Cloudflare DDNS 首次配置已成功保存! 🎉${NC}"
  echo -e "${GREEN}配置文件路径: ${CONFIG_FILE}${NC}"
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${YELLOW}下一步: 您可以通过主菜单的 '${CYAN}⚡ 手动运行更新${YELLOW}' (选项 4) 来测试您的配置。${NC}"
  read -p "按回车键返回主菜单..."
}

# 新增：专门用于首次配置向导的 Telegram 配置函数
configure_telegram_in_wizard_mode() {
  local enable_tg_initial
  echo -e "${PURPLE}您希望在每次 IP 更新时通过 Telegram 接收通知吗?${NC}"
  read -p "$(echo -e "${PURPLE}是否启用 Telegram 通知？ [Y/n]: ${NC}")" enable_tg_initial
  if [[ ! "${enable_tg_initial,,}" =~ ^n$ ]]; then
    echo -e "${GREEN}✅ 已选择启用 Telegram 通知。${NC}"
    configure_telegram # 直接调用通用 Telegram 配置函数，它会询问 Token/Chat ID 并发送测试消息
  else
    TG_BOT_TOKEN="" # 确保禁用时清空
    TG_CHAT_ID=""   # 确保禁用时清空
    log_message INFO "Telegram 通知功能已禁用。" # 日志记录
    echo -e "${YELLOW}ℹ️ 您选择了不启用 Telegram 通知。您可以在后续的 ${CYAN}'修改 DDNS 配置'${YELLOW} (主菜单选项 2) 中随时启用。${NC}\n"
    sleep 2 # 稍作停留，让用户看到提示
  fi
}


# =====================================================================
# 主流程函数
# =====================================================================

save_config() {
  log_message INFO "正在保存配置到 $CONFIG_FILE..."
  {
    echo "# CloudFlare DDNS 配置文件"
    echo "# 生成时间: $(date)"
    echo ""
    echo "CFKEY='$CFKEY'"
    echo "CFUSER='$CFUSER'"
    echo "CFZONE_NAME='$CFZONE_NAME'"
    echo "CFTTL=$CFTTL"
    echo "FORCE=$FORCE"
    echo ""
    echo "# IPv4 (A 记录) 配置"
    echo "ENABLE_IPV4=${ENABLE_IPV4}"
    echo "CFRECORD_NAME_V4='${CFRECORD_NAME_V4}'"
    echo ""
    echo "# IPv6 (AAAA 记录) 配置"
    echo "ENABLE_IPV6=${ENABLE_IPV6}"
    echo "CFRECORD_NAME_V6='${CFRECORD_NAME_V6}'"
    echo ""
    echo "# Telegram 通知配置"
    echo "TG_BOT_TOKEN='${TG_BOT_TOKEN}'"
    echo "TG_CHAT_ID='${TG_CHAT_ID}'"
  } > "$CONFIG_FILE"
  
  chmod 600 "$CONFIG_FILE"
  log_message SUCCESS "配置已保存并设置了权限。"
}

load_config() {
  # 确保所有变量在加载前被清空或设置为默认值，以避免旧值残留
  CFKEY=""
  CFUSER=""
  CFZONE_NAME=""
  CFTTL=120
  FORCE=false
  ENABLE_IPV4=true
  CFRECORD_NAME_V4=""
  ENABLE_IPV6=true
  CFRECORD_NAME_V6=""
  TG_BOT_TOKEN=""
  TG_CHAT_ID=""

  if [ -f "$CONFIG_FILE" ]; then
    # 使用 `eval` 可能会有安全风险，但对于已知来源的配置文件，通常是可接受的。
    # 更安全的替代方案是手动解析文件内容，但会增加复杂性。
    # 鉴于脚本的目标和权限要求，这里的 eval 是可行的。
    set -a; . "$CONFIG_FILE"; set +a
    
    # 确保加载后的变量都有默认值（防止配置文件中缺少某项）
    CFKEY="${CFKEY:-}"
    CFUSER="${CFUSER:-}"
    CFZONE_NAME="${CFZONE_NAME:-}"
    CFTTL="${CFTTL:-120}"
    FORCE="${FORCE:-false}"
    ENABLE_IPV4="${ENABLE_IPV4:-true}"
    CFRECORD_NAME_V4="${CFRECORD_NAME_V4:-}"
    ENABLE_IPV6="${ENABLE_IPV6:-true}"
    CFRECORD_NAME_V6="${CFRECORD_NAME_V6:-}"
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_CHAT_ID="${TG_CHAT_ID:-}"
    return 0
  fi
  return 1
}

add_cron_job() {
  local script_path
  script_path=$(realpath "$0")
  local current_cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_JOB_ID")
  local existing_schedule=""

  if [[ -n "$current_cron_entry" ]]; then
    log_message INFO "找到现有定时任务，正在更新..."
    # 从现有任务中提取频率，如果存在且格式正确
    existing_schedule=$(echo "$current_cron_entry" | awk '{print $1, $2, $3, $4, $5}')
  fi
  
  # 如果没有获取到有效频率，或者没有现有任务，则使用默认频率
  local cron_schedule="${existing_schedule:-$DEFAULT_CRON_SCHEDULE}" 

  # 移除旧的定时任务条目（如果存在）
  remove_cron_job_only_entry

  local cron_command="$cron_schedule $script_path update >> '$LOG_FILE' 2>&1 # $CRON_JOB_ID"
  (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
  log_message SUCCESS "定时任务已添加/更新为: $cron_schedule"
}

remove_cron_job_only_entry() {
  if crontab -l 2>/dev/null | grep -q "$CRON_JOB_ID"; then
    crontab -l | grep -v "$CRON_JOB_ID" | crontab -
    log_message SUCCESS "成功移除了旧的定时任务条目。"
  else
    log_message INFO "未找到现有定时任务可供移除。"
  fi
}

# --- 卸载DDNS ---
uninstall_ddns() {
  clear
  echo -e "${RED}--- 警告: 即将完全卸载 Cloudflare DDNS ---${NC}"
  echo -e "${YELLOW}此操作将删除所有相关的配置文件、数据、日志以及脚本本身和定时任务。${NC}"
  read -p "$(echo -e "${PURPLE}您确定要继续吗? [y/N]: ${NC}")" confirm
  if [[ ! "${confirm,,}" =~ ^y$ ]]; then
    log_message INFO "取消卸载操作。" # 日志记录
    echo -e "${YELLOW}取消卸载。${NC}"; sleep 1; return
  fi

  log_message INFO "正在启动 DDNS 完全卸载过程。"
  echo -e "${BLUE}开始卸载...${NC}"

  # 1. 移除定时任务
  remove_cron_job_only_entry # 只移除条目，不打印“成功移除”信息到屏幕，避免重复
  log_message SUCCESS "已移除定时任务。" # 统一日志
  echo -e "${GREEN}✅ 已移除定时任务。${NC}"

  # 2. 删除数据目录 (包括IP缓存文件)
  if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR"
    log_message SUCCESS "已删除数据目录: ${DATA_DIR}" # 统一日志
    echo -e "${GREEN}✅ 已删除数据目录: ${DATA_DIR}${NC}"
  else
    log_message WARN "数据目录不存在: ${DATA_DIR}" # 统一日志
    echo -e "${YELLOW}ℹ️ 数据目录不存在: ${DATA_DIR}${NC}"
  fi

  # 3. 删除配置目录 (包括配置文件)
  if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    log_message SUCCESS "已删除配置目录: ${CONFIG_DIR}" # 统一日志
    echo -e "${GREEN}✅ 已删除配置目录: ${CONFIG_DIR}${NC}"
  else
    log_message WARN "配置目录不存在: ${CONFIG_DIR}" # 统一日志
    echo -e "${YELLOW}ℹ️ 配置目录不存在: ${CONFIG_DIR}${NC}"
  fi

  # 4. 删除日志文件
  if [ -f "$LOG_FILE" ]; then
    rm -f "$LOG_FILE"
    log_message SUCCESS "已删除日志文件: ${LOG_FILE}" # 统一日志
    echo -e "${GREEN}✅ 已删除日志文件: ${LOG_FILE}${NC}"
  else
    log_message WARN "日志文件不存在: ${LOG_FILE}" # 统一日志
    echo -e "${YELLOW}ℹ️ 日志文件不存在: ${LOG_FILE}${NC}"
  fi

  # 5. 删除脚本本身和快捷方式
  local system_script_path="/usr/local/bin/cf-ddns"
  local shortcut_link="/usr/local/bin/d"

  if [ -f "$system_script_path" ]; then
    rm -f "$system_script_path"
    log_message SUCCESS "已删除主脚本: ${system_script_path}" # 统一日志
    echo -e "${GREEN}✅ 已删除主脚本: ${system_script_path}${NC}"
  else
    log_message WARN "主脚本不存在: ${system_script_path}" # 统一日志
    echo -e "${YELLOW}ℹ️ 主脚本不存在: ${system_script_path}${NC}"
  fi
  
  if [ -L "$shortcut_link" ] || [ -f "$shortcut_link" ]; then
    rm -f "$shortcut_link"
    log_message SUCCESS "已删除快捷方式: ${shortcut_link}" # 统一日志
    echo -e "${GREEN}✅ 已删除快捷方式: ${shortcut_link}${NC}"
  else
    log_message WARN "快捷方式不存在: ${shortcut_link}" # 统一日志
    echo -e "${YELLOW}ℹ️ 快捷方式不存在: ${shortcut_link}${NC}"
  fi

  log_message SUCCESS "Cloudflare DDNS 已完全卸载。"
  echo -e "\n${GREEN}🎉 Cloudflare DDNS 已完全卸载。所有相关文件均已移除。${NC}"
  echo -e "${YELLOW}脚本即将自动退出。${NC}"
  # 退出脚本，因为脚本自身可能已经被删除
  exit 0
}

# --- 显示修改菜单的函数 ---
show_modify_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${BLUE}           ⚙️ 修改 DDNS 配置 ⚙️                 ${NC}"
    echo -e "${CYAN}==============================================${NC}"
    show_current_config # 先显示当前配置概览
    echo -e "${YELLOW}选择您想修改的配置项:${NC}"
    echo -e "${GREEN} 1. 基础配置 (API密钥, 邮箱, 主域名)${NC}"
    echo -e "${GREEN} 2. IPv4 (A 记录) 配置${NC}"
    echo -e "${GREEN} 3. IPv6 (AAAA 记录) 配置${NC}"
    echo -e "${GREEN} 4. Telegram 通知${NC}" # Telegram 通知现在在这里单独列出
    echo -e "${GREEN} 5. TTL 值${NC}"
    echo -e "${GREEN} 6. 返回主菜单${NC}"
    echo -e "${CYAN}==============================================${NC}"
    read -p "$(echo -e "${PURPLE}请输入选项 [1-6]: ${NC}")" modify_choice
}

# --- 修改配置 (核心重构) ---
modify_config() {
  log_message INFO "正在启动配置修改。"
  
  if ! load_config; then
    log_message ERROR "未找到现有配置，无法修改。"
    echo -e "${RED}❌ 错误: 未找到现有配置。请先安装。${NC}"
    read -p "按回车键返回..."
    return 1
  fi
  
  local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$backup_file"
  log_message INFO "旧配置已备份到: ${backup_file}" # 统一日志
  echo -e "${BLUE}ℹ️ 旧配置已备份到: ${backup_file}${NC}"
  sleep 1

  while true; do
    load_config
    show_modify_menu

    case $modify_choice in
        1) configure_base ;;
        2) configure_ipv4 ;;
        3) configure_ipv6 ;;
        4) 
            # 在修改菜单中，这里需要再次询问是否启用或禁用
            echo -e "\n${CYAN}--- 配置 Telegram 通知 ---${NC}"
            local enable_tg_modify
            read -p "$(echo -e "${PURPLE}您想启用或禁用 Telegram 通知吗？ (当前: $([[ -n "$TG_BOT_TOKEN" ]] && echo "已启用" || echo "已禁用")) [Y/n]: ${NC}")" enable_tg_modify
            if [[ ! "${enable_tg_modify,,}" =~ ^n$ ]]; then
                configure_telegram # 如果选择启用，则进入配置流程
            else
                TG_BOT_TOKEN="" # 禁用时清空
                TG_CHAT_ID=""   # 禁用时清空
                log_message INFO "Telegram 通知功能已通过修改菜单禁用。" # 日志记录
                echo -e "${YELLOW}❌ Telegram 通知功能已禁用。${NC}"
            fi
            continue 
            ;;
        5) configure_ttl ;;
        6) echo -e "${GREEN}返回主菜单...${NC}"; break ;;
        *) log_message WARN "修改配置时输入了无效选项: '$modify_choice'" # 日志记录
           echo -e "${RED}❌ 无效选项，请重新输入。${NC}"; sleep 1; continue ;;
    esac

    save_config
    # 仅当实际有配置更改时才考虑更新 cron job，这里简化为每次保存都更新
    add_cron_job 
    log_message SUCCESS "配置已更新并保存!" # 统一日志
    echo -e "\n${GREEN}✅ 配置已更新并保存!${NC}"
    read -p "按回车键继续..."
  done
}

# --- 安装DDNS ---
install_ddns() {
  clear; log_message INFO "正在启动 DDNS 安装。"
  init_dirs
  run_full_config_wizard
  add_cron_job
  
  local script_path dest_path
  script_path=$(realpath "$0")
  dest_path="/usr/local/bin/cf-ddns"
  if cp -f "$script_path" "$dest_path" && chmod 755 "$dest_path"; then
    log_message SUCCESS "脚本已安装到: ${dest_path}" # 统一日志
    echo -e "${GREEN}✅ 脚本已安装到: ${dest_path}${NC}"
  else
    log_message ERROR "未能将脚本安装到: ${dest_path}" # 统一日志
    echo -e "${RED}❌ 错误: 未能将脚本安装到: ${dest_path}${NC}"
  fi
  
  local shortcut_link="/usr/local/bin/d"
  if [ ! -e "$shortcut_link" ]; then
    if ln -s "$dest_path" "$shortcut_link"; then
      log_message SUCCESS "已创建快捷方式: ${shortcut_link}" # 统一日志
      echo -e "${GREEN}✅ 已创建快捷方式: 输入 '${CYAN}d${GREEN}' 即可快速启动。${NC}"
    else
      log_message WARN "未能创建快捷方式: ${shortcut_link}" # 统一日志
      echo -e "${YELLOW}⚠️ 警告: 未能创建快捷方式: ${shortcut_link}${NC}"
    fi
  fi
  
  echo -e "${BLUE}⚡ 正在运行首次更新...${NC}"
  run_ddns_update
  
  log_message INFO "安装完成。" # 统一日志
  echo -e "\n${GREEN}🎉 安装完成!${NC}"; read -p "按回车键返回主菜单..."
}

# --- 定时任务管理函数 ---
manage_cron_job() {
  clear
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${BLUE}          ⏱️ 定时任务管理 ⏱️                  ${NC}"
  echo -e "${CYAN}==============================================${NC}"
  
  local current_cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_JOB_ID")
  local script_path=$(realpath "$0")

  echo -e "${YELLOW}当前 DDNS 定时任务设置:${NC}"
  if [[ -n "$current_cron_entry" ]]; then
    echo -e "  ${GREEN}存在: ${current_cron_entry}${NC}"
    local current_schedule=$(echo "$current_cron_entry" | awk '{print $1, $2, $3, $4, $5}')
    echo -e "  ${GREEN}当前频率: ${current_schedule}${NC}"
  else
    echo -e "  ${RED}不存在或未识别到与本脚本关联的定时任务。${NC}"
    echo -e "  ${YELLOW}默认频率: ${DEFAULT_CRON_SCHEDULE} (每2分钟)${NC}"
  fi
  echo

  echo -e "${PURPLE}请选择新的更新频率或输入自定义 Cron 表达式:${NC}"
  echo -e "  ${GREEN}1. 每 2 分钟 (默认)  ${CYAN}[*/2 * * * *]${NC}"
  echo -e "  ${GREEN}2. 每 5 分钟        ${CYAN}[*/5 * * * *]${NC}"
  echo -e "  ${GREEN}3. 每 10 分钟       ${CYAN}[*/10 * * * *]${NC}"
  echo -e "  ${GREEN}4. 每 30 分钟       ${CYAN}[*/30 * * * *]${NC}"
  echo -e "  ${GREEN}5. 每 1 小时        ${CYAN}[0 * * * *]${NC}"
  echo -e "  ${GREEN}6. 自定义 Cron 表达式${NC}"
  echo -e "  ${RED}7. 返回主菜单${NC}"
  read -p "$(echo -e "${PURPLE}请输入选项 [1-7]: ${NC}")" cron_choice

  local new_cron_schedule=""
  local update_cron=false # 新增标志，只有在选择新频率时才更新cron
  case "$cron_choice" in
    1) new_cron_schedule="*/2 * * * *"; update_cron=true ;;
    2) new_cron_schedule="*/5 * * * *"; update_cron=true ;;
    3) new_cron_schedule="*/10 * * * *"; update_cron=true ;;
    4) new_cron_schedule="*/30 * * * *"; update_cron=true ;;
    5) new_cron_schedule="0 * * * *"; update_cron=true ;;
    6) 
      echo -e "${YELLOW}请输入自定义 Cron 表达式 (例如: '0 0 * * *' 每天午夜运行):${NC}"
      read -p "$(echo -e "${PURPLE}Cron 表达式: ${NC}")" custom_cron
      # 简单验证 Cron 表达式，确保包含5个字段
      if [[ $(echo "$custom_cron" | wc -w) -eq 5 ]]; then
        new_cron_schedule="$custom_cron"
        update_cron=true
      else
        log_message ERROR "无效的 Cron 表达式格式: '$custom_cron'" # 日志记录
        echo -e "${RED}❌ 无效的 Cron 表达式格式。请确保包含 5 个字段。${NC}"
        read -p "按回车键返回定时任务管理菜单..."
        manage_cron_job # 重新进入定时任务管理
        return
      fi
      ;;
    7) log_message INFO "返回主菜单。" # 日志记录
       echo -e "${GREEN}返回主菜单...${NC}"; sleep 1; return ;;
    *) 
      log_message WARN "定时任务管理时输入了无效选项: '$cron_choice'" # 日志记录
      echo -e "${RED}❌ 无效选项，请重新输入。${NC}"; 
      read -p "按回车键返回定时任务管理菜单..."
      manage_cron_job # 重新进入定时任务管理
      return
      ;;
  esac

  if "$update_cron"; then
    # 移除旧的定时任务
    remove_cron_job_only_entry
    
    # 添加新的定时任务
    local cron_command="$new_cron_schedule $script_path update >> '$LOG_FILE' 2>&1 # $CRON_JOB_ID"
    (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
    log_message SUCCESS "定时任务已更新为: $new_cron_schedule"
    echo -e "${GREEN}✅ 定时任务已成功更新为: ${new_cron_schedule}${NC}"
    echo -e "${YELLOW}请注意：新的定时任务将在下一次 Cron 调度时生效。${NC}"
  else
    log_message INFO "未更改定时任务频率。"
    echo -e "${YELLOW}ℹ️ 未更改定时任务频率。${NC}"
  fi
  read -p "按回车键返回主菜单..."
}


# --- 查看当前配置 ---
show_current_config() {
  echo -e "${CYAN}------------------- 当前配置 -------------------${NC}"
  if load_config; then
    echo -e "  ${YELLOW}基础配置:${NC}"
    echo -e "    API 密钥 : ${CFKEY:0:4}****${CFKEY: -4}"
    echo -e "    账户邮箱 : ${CFUSER}"
    echo -e "    主域名   : ${CFZONE_NAME}"
    echo -e "    TTL 值   : ${CFTTL} 秒"
    echo -e "  ${YELLOW}IPv4 (A 记录):${NC}"
    if [[ "$ENABLE_IPV4" == "true" ]]; then
        echo -e "    状态 : ${GREEN}已启用 ✅${NC}"
        echo -e "    域名 : ${CFRECORD_NAME_V4}"
    else
        echo -e "    状态 : ${RED}已禁用 ❌${NC}"
    fi
    echo -e "  ${YELLOW}IPv6 (AAAA 记录):${NC}"
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        echo -e "    状态 : ${GREEN}已启用 ✅${NC}"
        echo -e "    域名 : ${CFRECORD_NAME_V6}"
    else
        echo -e "    状态 : ${RED}已禁用 ❌${NC}"
    fi
    echo -e "  ${YELLOW}Telegram 通知:${NC}"
    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
      echo -e "    状态 : ${GREEN}已启用 ✅"
      echo -e "    Bot Token: ${TG_BOT_TOKEN:0:10}..."
      echo -e "    Chat ID  : ${TG_CHAT_ID}${NC}"
    else
      echo -e "    状态 : ${RED}已禁用 ❌${NC}"
    fi
  else
    log_message WARN "尝试查看配置但未找到有效配置。" # 日志记录
    echo -e "  ${RED}未找到有效配置。请先安装 DDNS。${NC}"
  fi
  echo -e "${CYAN}-------------------------------------------------${NC}"
}

# --- 查看日志 ---
view_logs() {
  clear
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${BLUE}          📜 查看 DDNS 日志 📜              ${NC}"
  echo -e "${CYAN}==============================================${NC}"
  log_message INFO "用户正在查看日志文件: ${LOG_FILE}" # 日志记录
  
  echo -e "${YELLOW}日志文件路径: ${CYAN}${LOG_FILE}${NC}\n"
  echo -e "${YELLOW}提示: 在日志查看器中，按 ${CYAN}'q'${YELLOW} 退出，按 ${CYAN}'Space'${YELLOW} 向下翻页，按 ${CYAN}'G'${YELLOW} 跳转到文件末尾。${NC}"
  echo -e "${YELLOW}日志将自动显示最新内容。${NC}\n" # 增加一行，提示将自动显示最新内容

  # 增加一个短暂的暂停，让用户有时间阅读提示
  echo -e "${BLUE}即将打开日志文件...${NC}"
  sleep 2 # 暂停2秒

  if [ -f "$LOG_FILE" ]; then
    less -R -N +G "$LOG_FILE"
  else
    log_message ERROR "日志文件不存在: ${LOG_FILE}" # 日志记录
    echo -e "${RED}❌ 日志文件不存在: ${LOG_FILE}${NC}"
  fi
  read -p "按回车键返回主菜单..."
}

# =====================================================================
# 核心 DDNS 逻辑函数
# =====================================================================

send_tg_notification() {
  local message="$1"
  if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then return 0; fi # 如果没有配置 Telegram，则直接返回成功
  local response
  response=$(curl -s --show-error -m 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" -d "text=${message}" -d "parse_mode=Markdown")
  if [[ "$response" == *"\"ok\":true"* ]]; then return 0; else log_message ERROR "Telegram 通知失败: $response"; return 1; fi
}

get_wan_ip() {
  local record_type=$1 record_name=$2
  local ip_sources=() ip="" retries=3 success=false
  
  if [[ "$record_type" == "A" ]]; then ip_sources=("${WANIPSITE_v4[@]}"); else ip_sources=("${WANIPSITE_v6[@]}"); fi
  
  for (( i=0; i<retries; i++ )); do
    for source in "${ip_sources[@]}"; do
      local curl_flags=""
      if [[ "$record_type" == "A" ]]; then curl_flags="-4"; else curl_flags="-6"; fi
      
      ip=$(curl -s --show-error -m 5 "$curl_flags" "$source" | tr -d '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([a-fA-F0-9:]{2,39})')
      
      if [[ -n "$ip" ]]; then
        log_message INFO "成功从 $source 获取到 $record_type IP: $ip (尝试 ${i+1}/${retries})"
        echo "$ip"
        success=true
        break 2 # 成功获取IP后跳出所有循环
      else
        log_message WARN "从 $source 获取 $record_type IP 失败 (尝试 ${i+1}/${retries})"
      fi
    done
    if ! "$success"; then sleep 2; fi # 每次重试前等待
  done

  if ! "$success"; then
    log_message ERROR "未能从所有来源获取 $record_type IP (域名: $record_name) 经过 $retries 次尝试。"
    send_tg_notification "❌ *Cloudflare DDNS 错误* ❌

*无法获取公网 IP 地址!*
域名: \`$record_name\`
类型: \`$record_type\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请检查网络连接或 IP 检测服务。"
    return 1
  fi
  return 0
}

update_record() {
  local record_type=$1 record_name=$2 wan_ip=$3
  local id_file="$DATA_DIR/.cf-id_${record_name//./_}_${record_type}.txt"
  local id_zone="" id_record=""
  
  if [[ -f "$id_file" ]]; then
    id_zone=$(head -1 "$id_file" 2>/dev/null)
    id_record=$(sed -n '2p' "$id_file" 2>/dev/null)
  fi
  
  local zone_response
  # 每次都尝试获取 zone ID，以防缓存失效或首次运行
  zone_response=$(curl -s -m 10 -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json")
  
  local zone_success=$(echo "$zone_response" | jq -r '.success' 2>/dev/null)
  if [[ "$zone_success" != "true" ]]; then
    local error_messages=$(echo "$zone_response" | jq -r '.errors[].message' 2>/dev/null | paste -sd ", ")
    log_message ERROR "无法获取区域 ID for $CFZONE_NAME。API 错误: ${error_messages}. 响应: $zone_response"
    send_tg_notification "❌ *Cloudflare DDNS 错误* ❌

*无法获取 Cloudflare 区域 (Zone) ID!*
域名: \`$CFZONE_NAME\`
错误: \`${error_messages:-未知错误}\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请检查 API 密钥和账户邮箱是否正确，并确保主域名存在于您的 Cloudflare 账户下。"
    return 1
  fi
  id_zone=$(echo "$zone_response" | jq -r '.result[] | select(.name == "'"$CFZONE_NAME"'") | .id' 2>/dev/null)
  
  if [ -z "$id_zone" ]; then
    log_message ERROR "无法从 Cloudflare 获取到有效区域 ID for $CFZONE_NAME。"
    send_tg_notification "❌ *Cloudflare DDNS 错误* ❌

*无法从 Cloudflare 获取到有效区域 (Zone) ID!*
域名: \`$CFZONE_NAME\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`

⚠️ 请确保您的主域名在 Cloudflare 上已激活且配置正确。"
    return 1
  fi

  local record_response
  # 每次都尝试获取记录 ID，以防缓存失效或记录不存在
  record_response=$(curl -s -m 10 -X GET "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records?name=$record_name&type=$record_type" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json")
  
  local record_success=$(echo "$record_response" | jq -r '.success' 2>/dev/null)
  if [[ "$record_success" != "true" ]]; then
    local error_messages=$(echo "$record_response" | jq -r '.errors[].message' 2>/dev/null | paste -sd ", ")
    log_message ERROR "无法查询 DNS 记录 for $record_name。API 错误: ${error_messages}. 响应: $record_response"
    send_tg_notification "❌ *Cloudflare DDNS 错误* ❌

*无法查询 DNS 记录!*
域名: \`$record_name\`
类型: \`$record_type\`
错误: \`${error_messages:-未知错误}\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`"
    return 1
  fi
  id_record=$(echo "$record_response" | jq -r '.result[] | select(.type == "'"$record_type"'") | .id' 2>/dev/null)
  
  local api_data
  api_data="{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$wan_ip\", \"ttl\":$CFTTL,\"proxied\":false}"

  if [ -z "$id_record" ]; then
    log_message INFO "找不到记录，正在为 $record_name 创建新记录..."
    local create_response
    create_response=$(curl -s -m 10 -X POST "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" --data "$api_data")
    if echo "$create_response" | grep -q "\"success\":true"; then
      id_record=$(echo "$create_response" | jq -r '.result.id')
      log_message SUCCESS "成功创建记录 $record_name。"
    else
      local error_messages=$(echo "$create_response" | jq -r '.errors[].message' 2>/dev/null | paste -sd ", ")
      log_message ERROR "创建记录失败: ${error_messages}. 完整响应: $create_response"; 
      send_tg_notification "❌ *Cloudflare DDNS 错误* ❌

*创建 DNS 记录失败!*
域名: \`$record_name\`
尝试 IP: \`$wan_ip\`
错误: \`${error_messages:-未知错误}\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`"
      return 1;
    fi
  else
    log_message INFO "找到记录 ID: $id_record, 正在更新..."
    local update_response
    update_response=$(curl -s -m 10 -X PUT "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records/$id_record" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" --data "$api_data")
    if ! echo "$update_response" | grep -q "\"success\":true"; then
        local error_messages=$(echo "$update_response" | jq -r '.errors[].message' 2>/dev/null | paste -sd ", ")
        log_message ERROR "更新 $record_type 记录失败。API 错误: ${error_messages}. 响应: $update_response"
        send_tg_notification "❌ *Cloudflare DDNS 更新失败* ❌

*更新记录失败!*
域名: \`$record_name\`
尝试 IP: \`$wan_ip\`
错误: \`${error_messages:-未知错误}\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`"
        return 1
    fi
  fi
  
  printf "%s\n%s" "$id_zone" "$id_record" > "$id_file"
  log_message SUCCESS "成功将 $record_name 的 $record_type 记录更新为 $wan_ip。"
  return 0
}
 
process_record_type() {
  local record_type=$1 record_name=$2
  
  if [ -z "$record_name" ]; then
    log_message WARN "未配置 $record_type 记录的域名，跳过更新。"
    return 0
  fi

  local ip_file="$DATA_DIR/.cf-wan_ip_${record_name//./_}_${record_type}.txt"
  local current_ip="" old_ip=""
  
  log_message INFO "正在处理 $record_name 的 $record_type 记录。"
  
  if ! current_ip=$(get_wan_ip "$record_type" "$record_name"); then
    log_message ERROR "未能获取当前 $record_type IP。跳过 $record_name 的更新。"
    return 1
  fi
  
  if [[ -f "$ip_file" ]]; then old_ip=$(cat "$ip_file"); fi
  
  if [[ "$current_ip" != "$old_ip" ]] || [[ "$FORCE" == "true" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      log_message INFO "$record_type IP ($record_name) 强制更新，当前IP: '$current_ip'。"
    else
      log_message INFO "$record_type IP ($record_name) 已从 '${old_ip:-无}' 更改为 '$current_ip'。"
    fi
    
    if update_record "$record_type" "$record_name" "$current_ip"; then
      echo "$current_ip" > "$ip_file"
      log_message SUCCESS "$record_type IP ($record_name) 已成功更新并保存。"
      
      send_tg_notification "✅ *Cloudflare DDNS 更新成功* ✅

域名: \`$record_name\`
类型: \`$record_type\`
新 IP: \`$current_ip\`
旧 IP: \`${old_ip:-无}\`
时间: \`$(date +"%Y-%m-%d %H:%M:%S %Z")\`"
    else
      log_message ERROR "更新 $record_name ($record_type) 记录失败。"
      return 1
    fi
  else
    log_message INFO "$record_type IP ($record_name) 地址未更改: $current_ip。"
  fi
  return 0
}

run_ddns_update() {
  log_message INFO "--- 启动动态 DNS 更新过程 ---"
  echo -e "${BLUE}⚡ 正在启动动态 DNS 更新...${NC}"
  
  if ! load_config; then
    log_message ERROR "找不到配置文件或配置不完整。"
    send_tg_notification "❌ *Cloudflare DDNS 错误* ❌\n\n*配置文件缺失或不完整!*"
    echo -e "${RED}❌ 错误: 配置文件缺失或不完整。${NC}"
    exit 1
  fi
  
  if [[ -z "$CFKEY" || -z "$CFUSER" || -z "$CFZONE_NAME" ]]; then
    log_message ERROR "缺少必要的 Cloudflare 配置参数。"
    send_tg_notification "❌ *Cloudflare DDNS 错误* ❌\n\n*缺少必要的 Cloudflare 配置参数!*"
    echo -e "${RED}❌ 错误: 缺少必要的 Cloudflare 配置参数。${NC}"
    exit 1
  fi

  if [[ "$ENABLE_IPV4" == "false" && "$ENABLE_IPV6" == "false" ]]; then
      log_message WARN "IPv4 和 IPv6 更新均已禁用。无操作可执行。"
      echo -e "${YELLOW}ℹ️ IPv4 和 IPv6 更新均已禁用。无操作可执行。${NC}"
      exit 0 # 警告退出，而非错误退出
  fi
  
  local update_status_v4=0 update_status_v6=0

  if [[ "$ENABLE_IPV4" == "true" ]]; then
    process_record_type "A" "$CFRECORD_NAME_V4" || update_status_v4=$?
  fi
  
  if [[ "$ENABLE_IPV6" == "true" ]]; then
    process_record_type "AAAA" "$CFRECORD_NAME_V6" || update_status_v6=$?
  fi
  
  if [ "$update_status_v4" -eq 0 ] && [ "$update_status_v6" -eq 0 ]; then
    log_message SUCCESS "--- 动态 DNS 更新过程完成 ---"
    echo -e "${GREEN}✅ 动态 DNS 更新过程成功完成。${NC}"
  else
    log_message ERROR "--- 动态 DNS 更新过程完成但有错误 ---"
    echo -e "${RED}❌ 动态 DNS 更新过程完成但有错误。请查看日志。${NC}"
  fi
}

# =====================================================================
# 主程序入口
# =====================================================================
main() {
  # 检查依赖并提供安装建议
  local missing_deps=()
  for dep in curl grep sed jq; do
    if ! command -v "$dep" &>/dev/null; then
      missing_deps+=("$dep")
    fi
  done

  if [ "${#missing_deps[@]}" -gt 0 ]; then
    echo -e "${RED}❌ 错误: 缺少以下必要的依赖: ${missing_deps[*]}. 请先安装。${NC}" >&2
    echo -e "${YELLOW}建议安装命令 (以 Debian/Ubuntu 为例): ${NC}sudo apt update && sudo apt install ${missing_deps[*]}${NC}" >&2
    echo -e "${YELLOW}建议安装命令 (以 CentOS/RHEL 为例): ${NC}sudo yum install ${missing_deps[*]}${NC}" >&2
    exit 1
  fi

  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ 错误: 此脚本需要 root 权限运行。请使用 'sudo' 执行。${NC}" >&2
    # 允许在非root下查看日志
    if [[ $# -eq 1 && "$1" == "log" ]]; then
        view_logs
        exit 0
    fi
    exit 1
  fi
  
  init_dirs

  # 获取当前脚本的真实路径
  local current_script_real_path
  current_script_real_path="$(realpath "$0")"

  if [ $# -gt 0 ]; then
    case "$1" in
      update) run_ddns_update; exit 0 ;;
      install) install_ddns; exit 0 ;;
      modify) modify_config; exit 0 ;;
      uninstall) 
        # 如果是命令行直接调用 uninstall，则调用卸载函数，它会自行退出
        uninstall_ddns
        exit 0 # 确保卸载后退出
        ;;
      log) view_logs; exit 0 ;;
      cron) manage_cron_job; exit 0 ;; # 新增命令行参数支持
      rotate_log_daily) rotate_logs "$LOG_FILE"; exit 0 ;; # 新增用于 cron 调用的日志轮换命令
      *)
        echo -e "${RED}❌ 无效参数: ${1}${NC}"
        echo -e "${YELLOW}用法: ${NC}$(basename "$0") ${GREEN}[update|install|modify|uninstall|log|cron|rotate_log_daily]${NC}"
        exit 1
        ;;
    esac
  fi

  while true; do
    show_main_menu
    case $main_choice in
      1) install_ddns ;;
      2) modify_config ;;
      3) clear; show_current_config; read -p "按回车键返回主菜单..." ;;
      4) echo -e "${YELLOW}⚡ 正在手动运行更新...${NC}"; run_ddns_update; read -p "按回车键返回..." ;;
      5) manage_cron_job ;; # 调用新的定时任务管理函数
      6) view_logs ;;
      7) uninstall_ddns ;;
      8) echo -e "${GREEN}👋 退出脚本。再见!${NC}"; exit 0 ;;
      *) echo -e "${RED}❌ 无效选项，请重新输入。${NC}"; sleep 2 ;;
    esac
  done
}

# 执行主函数
main "$@"