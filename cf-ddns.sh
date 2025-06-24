#!/usr/bin/env bash
# Cloudflare DDNS 管理脚本 (功能完整优化版)
# 版本: 2.5


# 严格的错误处理：
set -o errexit
set -o nounset
set -o pipefail

# --- 全局变量和配置路径 ---
CONFIG_DIR="/etc/cf-ddns"
DATA_DIR="/var/lib/cf-ddns"
CONFIG_FILE="$CONFIG_DIR/config.conf"
LOG_FILE="/var/log/cf-ddns.log"
CRON_JOB_ID="CLOUDFLARE_DDNS_JOB"
DEFAULT_CRON_SCHEDULE="*/2 * * * *"
INSTALLED_SCRIPT_PATH="/usr/local/bin/cf-ddns"

# --- 默认配置参数 ---
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
TIMEZONE="Asia/Shanghai"

# 设置时区
export TZ="${TIMEZONE}"

# --- 公网 IP 检测服务 ---
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
NC='\033[0m'

# =====================================================================
# 实用函数
# =====================================================================

log_message() {
  local level="$1" message="$2"
  local timestamp
  timestamp="$(TZ="$TIMEZONE" date +"%Y-%m-%d %H:%M:%S %Z")"
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
  local level_color="${NC}"
  case "$level" in
    "INFO") level_color="${BLUE}" ;; "WARN") level_color="${YELLOW}" ;;
    "ERROR") level_color="${RED}" ;; "SUCCESS") level_color="${GREEN}" ;;
  esac
  echo -e "${level_color}$(TZ="$TIMEZONE" date +"%H:%M:%S") [$level] $message${NC}" >&2
}

show_main_menu() {
  clear
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${BLUE}     🚀 CloudFlare DDNS 管理脚本 🚀     ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  # 【已更新】修改菜单文本
  echo -e "${GREEN} 1. ✨ 更新/安装 DDNS${NC}"
  echo -e "${GREEN} 2. ⚙️ 修改 DDNS 配置${NC}"
  echo -e "${GREEN} 3. 📋 查看当前配置${NC}"
  echo -e "${GREEN} 4. ⚡ 手动运行更新${NC}"
  echo -e "${GREEN} 5. ⏱️ 定时任务管理${NC}"
  echo -e "${GREEN} 6. 📜 查看日志${NC}"
  echo -e "${GREEN} 7. 🗑️ 卸载 DDNS${NC}"
  echo -e "${GREEN} 8. 🚪 退出脚本${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo
  read -p "$(echo -e "${PURPLE}请选择一个操作 [1-8]: ${NC}")" main_choice
}

init_dirs() {
  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  chmod 700 "$CONFIG_DIR" "$DATA_DIR"
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
}

# =====================================================================
# 配置功能模块 (完整交互)
# =====================================================================

configure_base() {
  echo -e "\n${CYAN}--- 1. 修改基础配置 ---${NC}"
  local new_key new_user new_zone
  read -p "$(echo -e "${PURPLE}请输入 Cloudflare API 密钥 (当前: ${CFKEY:0:4}****${CFKEY: -4}, 直接回车保留): ${NC}")" new_key
  CFKEY=${new_key:-$CFKEY}
  while ! [[ "$CFKEY" =~ ^[a-zA-Z0-9]{37}$ ]]; do read -p "$(echo -e "${RED}❌ 密钥格式无效，请重新输入: ${NC}")" CFKEY; done
  echo -e "${GREEN}✅ API 密钥已更新。${NC}\n"

  read -p "$(echo -e "${PURPLE}请输入 Cloudflare 账户邮箱 (当前: $CFUSER, 直接回车保留): ${NC}")" new_user
  CFUSER=${new_user:-$CFUSER}
  while ! [[ "$CFUSER" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do read -p "$(echo -e "${RED}❌ 邮箱格式无效，请重新输入: ${NC}")" CFUSER; done
  echo -e "${GREEN}✅ 邮箱已更新。${NC}\n"

  read -p "$(echo -e "${PURPLE}请输入您的主域名 (当前: $CFZONE_NAME, 直接回车保留): ${NC}")" new_zone
  CFZONE_NAME=${new_zone:-$CFZONE_NAME}
  while ! [[ "$CFZONE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do read -p "$(echo -e "${RED}❌ 域名格式无效，请重新输入: ${NC}")" CFZONE_NAME; done
  echo -e "${GREEN}✅ 域名区域已更新。${NC}\n"
}

configure_ipv4() {
  echo -e "\n${CYAN}--- 2. 修改 IPv4 (A 记录) 配置 ---${NC}"
  local current_status="n" && [[ "$ENABLE_IPV4" == "true" ]] && current_status="Y"
  read -p "$(echo -e "${PURPLE}是否启用 IPv4 DDNS 解析? [Y/n] (当前: ${current_status}): ${NC}")" enable_v4; enable_v4=${enable_v4:-$current_status}
  if [[ ! "${enable_v4,,}" =~ ^n$ ]]; then
    ENABLE_IPV4=true; echo -e "${GREEN}✅ 已启用 IPv4 解析。${NC}"
    local current_record_v4=""; if [[ -n "$CFRECORD_NAME_V4" && -n "$CFZONE_NAME" && "$CFRECORD_NAME_V4" == *"$CFZONE_NAME"* ]]; then current_record_v4=${CFRECORD_NAME_V4%.$CFZONE_NAME}; if [[ "$current_record_v4" == "$CFRECORD_NAME_V4" ]]; then current_record_v4="@"; fi; fi
    read -p "$(echo -e "${PURPLE}请输入用于 IPv4 的主机记录 (当前: ${current_record_v4}, 直接回车保留): ${NC}")" record_name_v4_input; record_name_v4_input=${record_name_v4_input:-$current_record_v4}
    if [ -n "$record_name_v4_input" ] && [[ "$record_name_v4_input" =~ ^[a-zA-Z0-9.-_@]+$ ]]; then
      if [[ "$record_name_v4_input" == "@" ]]; then CFRECORD_NAME_V4="$CFZONE_NAME"; else CFRECORD_NAME_V4="${record_name_v4_input}.${CFZONE_NAME}"; fi
      echo -e "${GREEN}💡 IPv4 完整域名已更新为: ${CFRECORD_NAME_V4}${NC}"
    else echo -e "${RED}❌ 错误: 主机记录无效或为空! 保留原值。${NC}"; fi
  else ENABLE_IPV4=false; CFRECORD_NAME_V4=""; echo -e "${YELLOW}ℹ️ 已禁用 IPv4 解析。${NC}"; fi
}

configure_ipv6() {
  echo -e "\n${CYAN}--- 3. 修改 IPv6 (AAAA 记录) 配置 ---${NC}"
  local current_status="n" && [[ "$ENABLE_IPV6" == "true" ]] && current_status="Y"
  read -p "$(echo -e "${PURPLE}是否启用 IPv6 DDNS 解析? [Y/n] (当前: ${current_status}): ${NC}")" enable_v6; enable_v6=${enable_v6:-$current_status}
  if [[ ! "${enable_v6,,}" =~ ^n$ ]]; then
    ENABLE_IPV6=true; echo -e "${GREEN}✅ 已启用 IPv6 解析。${NC}"
    local current_record_v6=""; if [[ -n "$CFRECORD_NAME_V6" && -n "$CFZONE_NAME" && "$CFRECORD_NAME_V6" == *"$CFZONE_NAME"* ]]; then current_record_v6=${CFRECORD_NAME_V6%.$CFZONE_NAME}; if [[ "$current_record_v6" == "$CFRECORD_NAME_V6" ]]; then current_record_v6="@"; fi; fi
    read -p "$(echo -e "${PURPLE}请输入用于 IPv6 的主机记录 (当前: ${current_record_v6}, 直接回车保留): ${NC}")" record_name_v6_input; record_name_v6_input=${record_name_v6_input:-$current_record_v6}
    if [ -n "$record_name_v6_input" ] && [[ "$record_name_v6_input" =~ ^[a-zA-Z0-9.-_@]+$ ]]; then
      if [[ "$record_name_v6_input" == "@" ]]; then CFRECORD_NAME_V6="$CFZONE_NAME"; else CFRECORD_NAME_V6="${record_name_v6_input}.${CFZONE_NAME}"; fi
      echo -e "${GREEN}💡 IPv6 完整域名已更新为: ${CFRECORD_NAME_V6}${NC}"
    else echo -e "${RED}❌ 错误: 主机记录无效或为空! 保留原值。${NC}"; fi
  else ENABLE_IPV6=false; CFRECORD_NAME_V6=""; echo -e "${YELLOW}ℹ️ 已禁用 IPv6 解析。${NC}"; fi
}

configure_telegram() {
  echo -e "\n${CYAN}--- 🔔 配置 Telegram 通知详情 🔔 ---${NC}"
  read -p "$(echo -e "${PURPLE}请输入 Telegram Bot Token (当前: ${TG_BOT_TOKEN:0:10}..., 直接回车保留): ${NC}")" new_token; TG_BOT_TOKEN=${new_token:-$TG_BOT_TOKEN}
  while ! [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; do read -p "$(echo -e "${RED}❌ Token 格式无效! 请重新输入: ${NC}")" TG_BOT_TOKEN; done
  read -p "$(echo -e "${PURPLE}请输入 Telegram Chat ID (当前: $TG_CHAT_ID, 直接回车保留): ${NC}")" new_chat_id; TG_CHAT_ID=${new_chat_id:-$TG_CHAT_ID}
  while ! [[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]]; do read -p "$(echo -e "${RED}❌ Chat ID 必须是数字! 请重新输入: ${NC}")" TG_CHAT_ID; done
  echo -e "${BLUE}➡️ 正在尝试发送测试消息...${NC}"
  if send_tg_notification "🔔 *Cloudflare DDNS 配置测试* 🔔%0A%0A*测试成功!* ✅%0A时间: \`$(TZ="$TIMEZONE" date +"%Y-%m-%d %H:%M:%S %Z")\`"; then echo -e "${GREEN}✅ 测试消息发送成功!${NC}"; else echo -e "${RED}❌ 测试消息发送失败! 请检查 Token 和 Chat ID。${NC}"; fi
}

configure_ttl() {
  echo -e "\n${CYAN}--- 5. 修改 TTL 值 ---${NC}"
  read -p "$(echo -e "${PURPLE}请输入 DNS 记录的 TTL 值 (120-86400, 当前: $CFTTL, 直接回车保留): ${NC}")" ttl_input; ttl_input=${ttl_input:-$CFTTL}
  if [[ "$ttl_input" =~ ^[0-9]+$ ]] && [ "$ttl_input" -ge 120 ] && [ "$ttl_input" -le 86400 ]; then CFTTL="$ttl_input"; echo -e "${GREEN}✅ TTL 值已更新为: ${CFTTL} 秒。${NC}"; else echo -e "${RED}❌ 错误: TTL 值无效! 保留原值: $CFTTL。${NC}"; fi
}

configure_timezone() {
    echo -e "\n${CYAN}--- 6. 修改时区 ---${NC}"
    read -p "$(echo -e "${PURPLE}请输入时区 (例如: Asia/Shanghai, UTC, 当前: $TIMEZONE, 直接回车保留): ${NC}")" tz_input; tz_input=${tz_input:-$TIMEZONE}
    if TZ="$tz_input" date &>/dev/null; then TIMEZONE="$tz_input"; export TZ="$TIMEZONE"; echo -e "${GREEN}✅ 时区已更新为: $TIMEZONE${NC}"; else echo -e "${RED}❌ 错误: 无效的时区 '$tz_input'。保留原值: $TIMEZONE。${NC}"; fi
}

run_full_config_wizard() {
  clear
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${BLUE}      ✨ CloudFlare DDNS 首次配置向导 ✨         ${NC}"
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${YELLOW}欢迎使用! 此向导将引导您完成所有必要配置。${NC}\n"

  configure_base
  configure_ipv4
  configure_ipv6

  if [[ "$ENABLE_IPV4" == "false" && "$ENABLE_IPV6" == "false" ]]; then
    log_message ERROR "IPv4 和 IPv6 解析不能同时禁用!"
    echo -e "${RED}❌ 错误: 您必须至少启用一个解析类型。操作已终止，请重新安装。${NC}"
    exit 1
  fi

  configure_ttl
  configure_timezone

  echo -e "\n${CYAN}--- Telegram 通知配置 ---${NC}"
  read -p "$(echo -e "${PURPLE}是否需要配置 Telegram 通知？ [Y/n]: ${NC}")" enable_tg
  if [[ ! "${enable_tg,,}" =~ ^n$ ]]; then
    configure_telegram
  else
    TG_BOT_TOKEN=""; TG_CHAT_ID=""
    echo -e "${YELLOW}ℹ️ 已跳过 Telegram 配置。${NC}"
  fi

  save_config
  echo -e "\n${GREEN}🎉 恭喜! Cloudflare DDNS 基础配置已成功保存!${NC}"
}

# =====================================================================
# 主流程与核心功能函数
# =====================================================================

save_config() {
  log_message INFO "正在保存配置到 $CONFIG_FILE..."
  {
    echo "# CloudFlare DDNS 配置文件 (v2.5)"; echo "# 生成时间: $(TZ="$TIMEZONE" date)"; echo ""
    echo "CFKEY='$CFKEY'"; echo "CFUSER='$CFUSER'"; echo "CFZONE_NAME='$CFZONE_NAME'"
    echo "CFTTL=$CFTTL"; echo "FORCE=$FORCE"; echo "TIMEZONE='$TIMEZONE'"; echo ""
    echo "# IPv4 (A 记录) 配置"; echo "ENABLE_IPV4=${ENABLE_IPV4}"; echo "CFRECORD_NAME_V4='${CFRECORD_NAME_V4}'"; echo ""
    echo "# IPv6 (AAAA 记录) 配置"; echo "ENABLE_IPV6=${ENABLE_IPV6}"; echo "CFRECORD_NAME_V6='${CFRECORD_NAME_V6}'"; echo ""
    echo "# Telegram 通知配置"; echo "TG_BOT_TOKEN='${TG_BOT_TOKEN}'"; echo "TG_CHAT_ID='${TG_CHAT_ID}'"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  log_message SUCCESS "配置已成功保存并设置安全权限。"
}

load_config() {
  CFKEY=""; CFUSER=""; CFZONE_NAME=""; CFTTL=120; FORCE=false; ENABLE_IPV4=true; CFRECORD_NAME_V4=""
  ENABLE_IPV6=true; CFRECORD_NAME_V6=""; TG_BOT_TOKEN=""; TG_CHAT_ID=""; TIMEZONE="Asia/Shanghai"
  if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^\s*# || -z "$key" ]] && continue
      value=$(echo "$value" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//' | xargs)
      case "$key" in
        "CFKEY") CFKEY="$value" ;; "CFUSER") CFUSER="$value" ;; "CFZONE_NAME") CFZONE_NAME="$value" ;;
        "CFTTL") CFTTL="$value" ;; "FORCE") FORCE="$value" ;; "ENABLE_IPV4") ENABLE_IPV4="$value" ;;
        "CFRECORD_NAME_V4") CFRECORD_NAME_V4="$value" ;; "ENABLE_IPV6") ENABLE_IPV6="$value" ;;
        "CFRECORD_NAME_V6") CFRECORD_NAME_V6="$value" ;; "TG_BOT_TOKEN") TG_BOT_TOKEN="$value" ;;
        "TG_CHAT_ID") TG_CHAT_ID="$value" ;; "TIMEZONE") TIMEZONE="$value" ;;
      esac
    done < "$CONFIG_FILE"
    CFTTL="${CFTTL:-120}"; FORCE="${FORCE:-false}"; ENABLE_IPV4="${ENABLE_IPV4:-true}"; ENABLE_IPV6="${ENABLE_IPV6:-true}"; TIMEZONE="${TIMEZONE:-"Asia/Shanghai"}"
    export TZ="$TIMEZONE"
    return 0
  fi
  return 1
}

manage_cron_job() {
  clear
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${BLUE}          ⏱️ 定时任务频率设置 ⏱️                  ${NC}"
  echo -e "${CYAN}==============================================${NC}"
  local current_cron_entry; current_cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_JOB_ID")
  echo -e "${YELLOW}当前定时任务设置:${NC}"; if [[ -n "$current_cron_entry" ]]; then echo -e "  ${GREEN}已设置: ${current_cron_entry}${NC}"; else echo -e "  ${RED}未设置。${NC}"; fi; echo
  echo -e "${PURPLE}请选择更新频率 (默认是每2分钟):${NC}"
  echo -e "  ${GREEN}1. 每 2 分钟 (默认)  ${CYAN}[*/2 * * * *]${NC}"
  echo -e "  ${GREEN}2. 每 5 分钟        ${CYAN}[*/5 * * * *]${NC}"
  echo -e "  ${GREEN}3. 每 10 分钟       ${CYAN}[*/10 * * * *]${NC}"
  echo -e "  ${GREEN}4. 每 30 分钟       ${CYAN}[*/30 * * * *]${NC}"
  echo -e "  ${GREEN}5. 每 1 小时        ${CYAN}[0 * * * *]${NC}"
  echo -e "  ${GREEN}6. 自定义 Cron 表达式${NC}"
  echo -e "  ${GREEN}7. 返回${NC}"
  read -p "$(echo -e "${PURPLE}请输入选项 [1-7]: ${NC}")" cron_choice
  local new_schedule=""
  case "$cron_choice" in
    1) new_schedule="$DEFAULT_CRON_SCHEDULE" ;; 2) new_schedule="*/5 * * * *" ;; 3) new_schedule="*/10 * * * *" ;; 4) new_schedule="*/30 * * * *" ;; 5) new_schedule="0 * * * *" ;;
    6) read -p "$(echo -e "${YELLOW}请输入5段式 Cron 表达式: ${NC}")" custom_cron
       if [[ $(echo "$custom_cron" | wc -w) -eq 5 ]]; then new_schedule="$custom_cron"; else log_message ERROR "无效的 Cron 表达式: '$custom_cron'"; echo -e "${RED}❌ 无效格式。${NC}"; read -p "按回车键返回..." && return 1; fi ;;
    7) echo -e "${YELLOW}操作已取消。${NC}"; return 0 ;; *) echo -e "${RED}❌ 无效选项。${NC}"; sleep 1; return 1 ;;
  esac
  if [[ -n "$new_schedule" ]]; then
    (crontab -l 2>/dev/null | grep -v "$CRON_JOB_ID") | crontab -
    local cron_command="$new_schedule $INSTALLED_SCRIPT_PATH update >> '$LOG_FILE' 2>&1 # $CRON_JOB_ID"
    (crontab -l 2>/dev/null; echo "$cron_command") | crontab -
    log_message SUCCESS "定时任务已更新为: $new_schedule"; echo -e "${GREEN}✅ 定时任务已成功更新为: ${new_schedule}${NC}"
  fi
  read -p "按回车键继续..."
}

uninstall_ddns() {
  clear
  read -p "$(echo -e "${RED}警告: 您确定要完全卸载吗? [y/N]: ${NC}")" confirm
  if [[ ! "${confirm,,}" =~ ^y$ ]]; then echo -e "${YELLOW}取消卸载。${NC}"; return; fi
  
  log_message INFO "开始完全卸载DDNS...";
  
  (crontab -l 2>/dev/null | grep -v "$CRON_JOB_ID") | crontab -
  log_message INFO "已移除定时任务。"
  
  rm -rf "$DATA_DIR" "$CONFIG_DIR" "$LOG_FILE"
  log_message INFO "已删除数据、配置和日志目录/文件。"
  
  rm -f "$INSTALLED_SCRIPT_PATH" "/usr/local/bin/d" "/usr/local/bin/ddns"
  log_message INFO "已删除主程序脚本和所有快捷方式。"
  
  log_message SUCCESS "DDNS 已完全卸载。"
  echo -e "\n${GREEN}🎉 Cloudflare DDNS 已完全卸载。${NC}"
  
  local original_script_path
  original_script_path=$(realpath "$0")
  echo -e "\n${YELLOW}======================================================${NC}"
  echo -e "${YELLOW}❕ 请注意: 卸载程序已完成。${NC}"
  echo -e "${YELLOW}❕ 如果您最初用于运行此脚本的文件还在(例如在/tmp或下载目录中)，"
  echo -e "${YELLOW}❕ 您现在可以安全地手动删除它。路径为:${NC}"
  echo -e "${CYAN}   $original_script_path${NC}"
  echo -e "${YELLOW}======================================================${NC}"
  
  exit 0
}

show_modify_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"; echo -e "${BLUE}           ⚙️ 修改 DDNS 配置 ⚙️                 ${NC}"; echo -e "${CYAN}==============================================${NC}"
    show_current_config; echo -e "${YELLOW}选择您想修改的配置项:${NC}"
    echo -e "${GREEN} 1. 基础配置 (API密钥, 邮箱, 主域名)${NC}"; echo -e "${GREEN} 2. IPv4 (A 记录) 配置${NC}"; echo -e "${GREEN} 3. IPv6 (AAAA 记录) 配置${NC}"
    echo -e "${GREEN} 4. Telegram 通知${NC}"; echo -e "${GREEN} 5. TTL 值${NC}"; echo -e "${GREEN} 6. 时区 (Timezone)${NC}"; echo -e "${GREEN} 7. 返回主菜单${NC}"
    echo -e "${CYAN}==============================================${NC}"; read -p "$(echo -e "${PURPLE}请输入选项 [1-7]: ${NC}")" modify_choice
}

modify_config() {
  if ! load_config; then echo -e "${RED}❌ 错误: 未找到配置。请先安装。${NC}"; read -p "按回车键返回..." && return 1; fi
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  while true; do
    load_config; show_modify_menu
    case $modify_choice in
        1) configure_base ;; 2) configure_ipv4 ;; 3) configure_ipv6 ;; 4) configure_telegram ;; 5) configure_ttl ;; 6) configure_timezone ;;
        7) echo -e "${GREEN}返回主菜单...${NC}"; break ;; *) echo -e "${RED}❌ 无效选项。${NC}"; sleep 1; continue ;;
    esac
    save_config; echo -e "\n${GREEN}✅ 配置已更新并保存!${NC}"; read -p "按回车键继续..."
  done
}

# 【已更新】此函数现在也负责执行更新，而不仅仅是安装
install_ddns() {
  clear; log_message INFO "启动 DDNS 安装/更新流程。"
  # 如果是首次安装，则运行完整向导
  if [ ! -f "$CONFIG_FILE" ]; then
      run_full_config_wizard
  else
      echo -e "${GREEN}检测到现有配置，将直接更新脚本文件...${NC}"
      sleep 1
  fi

  # 执行脚本文件的复制和权限设置
  local current_script_path
  current_script_path=$(realpath "$0")
  cp -f "$current_script_path" "$INSTALLED_SCRIPT_PATH" && chmod 755 "$INSTALLED_SCRIPT_PATH"
  
  # 创建快捷键
  ln -sf "$INSTALLED_SCRIPT_PATH" "/usr/local/bin/d"
  ln -sf "$INSTALLED_SCRIPT_PATH" "/usr/local/bin/ddns"
  
  log_message SUCCESS "脚本已安装/更新到: ${INSTALLED_SCRIPT_PATH}, 并创建/更新了快捷方式。"
  echo -e "${GREEN}✅ 脚本已成功安装/更新，并设置了快捷方式 'd' 和 'ddns'。${NC}"

  # 如果是首次安装，则设置定时任务并运行首次更新
  if [ ! -f "$CONFIG_FILE" ]; then
    manage_cron_job
    echo -e "${BLUE}⚡ 正在运行首次更新...${NC}"; run_ddns_update
  fi
  
  log_message INFO "安装/更新完成。"; echo -e "\n${GREEN}🎉 操作完成!${NC}"; read -p "按回车键返回主菜单..."
}

show_current_config() {
  echo -e "${CYAN}------------------- 当前配置 -------------------${NC}"
  if load_config; then
    echo -e "  ${YELLOW}基础配置:${NC}"; echo -e "    API 密钥 : ${CFKEY:0:4}****${CFKEY: -4}"; echo -e "    账户邮箱 : ${CFUSER}"; echo -e "    主域名   : ${CFZONE_NAME}"; echo -e "    TTL 值   : ${CFTTL} 秒"; echo -e "    时区     : ${TIMEZONE}"
    echo -e "  ${YELLOW}IPv4 (A 记录):${NC}"; echo -e "    状态 : $([[ "$ENABLE_IPV4" == "true" ]] && echo -e "${GREEN}已启用 ✅${NC}" || echo -e "${RED}已禁用 ❌${NC}")"; [[ "$ENABLE_IPV4" == "true" ]] && echo -e "    域名 : ${CFRECORD_NAME_V4}"
    echo -e "  ${YELLOW}IPv6 (AAAA 记录):${NC}"; echo -e "    状态 : $([[ "$ENABLE_IPV6" == "true" ]] && echo -e "${GREEN}已启用 ✅${NC}" || echo -e "${RED}已禁用 ❌${NC}")"; [[ "$ENABLE_IPV6" == "true" ]] && echo -e "    域名 : ${CFRECORD_NAME_V6}"
  else echo -e "  ${RED}未找到有效配置。${NC}"; fi
  echo -e "${CYAN}-------------------------------------------------${NC}"
}

view_logs() {
  clear; echo -e "${CYAN}--- 查看 DDNS 日志 ---${NC}"; echo -e "${YELLOW}日志文件: ${LOG_FILE}${NC}\n"; if [ -f "$LOG_FILE" ]; then less -R -N +G "$LOG_FILE"; else echo -e "${RED}❌ 日志文件不存在。${NC}"; fi
  read -p "按回车键返回主菜单..."
}

# =====================================================================
# 核心 DDNS 逻辑与自动更新函数
# =====================================================================

perform_update() {
    local script_path="$1"
    local dest_path="$2"
    # 移除旧的快捷方式以防它们是指向旧位置的软链接
    rm -f "/usr/local/bin/d" "/usr/local/bin/ddns"
    
    log_message INFO "开始自动更新脚本..."
    if cp -f "$script_path" "$dest_path" && chmod 755 "$dest_path"; then
        # 重新创建快捷方式
        ln -sf "$dest_path" "/usr/local/bin/d"
        ln -sf "$dest_path" "/usr/local/bin/ddns"
        
        local script_version; script_version=$(grep -m 1 '版本:' "$dest_path" | awk '{print $3}')
        log_message SUCCESS "脚本已成功更新到版本 $script_version。"
        echo -e "${GREEN}✅ 脚本已更新至最新版本 ($script_version)。正在重新加载...${NC}"
        sleep 2
        # exec 命令会用新脚本进程替换当前进程，并保留传入的参数
        exec "$dest_path" "${@:3}"
    else
        log_message ERROR "自动更新失败！请尝试手动运行安装选项。"
        echo -e "${RED}❌ 自动更新失败！请检查权限。${NC}"
        exit 1
    fi
}

send_tg_notification() {
  local message="$1"; if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then return 0; fi
  local encoded_message; encoded_message=$(echo -n "$message" | jq -s -R -r @uri)
  local response; response=$(curl -s --show-error -m 10 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage?chat_id=${TG_CHAT_ID}&text=${encoded_message}&parse_mode=Markdown")
  if [[ $(echo "$response" | jq -r '.ok') == "true" ]]; then return 0; else log_message ERROR "Telegram 通知失败: $(echo "$response" | jq -r '.description')"; return 1; fi
}

get_wan_ip() {
  local record_type=$1 record_name=$2; local ip_sources=() ip=""
  if [[ "$record_type" == "A" ]]; then ip_sources=("${WANIPSITE_v4[@]}"); else ip_sources=("${WANIPSITE_v6[@]}"); fi
  for source in "${ip_sources[@]}"; do
    local curl_flags=$([[ "$record_type" == "A" ]] && echo "-4" || echo "-6")
    ip=$(curl -s --show-error -m 5 "$curl_flags" "$source" | tr -d '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([a-fA-F0-9:]{2,39})')
    if [[ -n "$ip" ]]; then log_message INFO "成功从 $source 获取到 $record_type IP: $ip"; echo "$ip"; return 0; fi
  done
  log_message ERROR "未能从所有来源获取 $record_type IP for $record_name。"; send_tg_notification "❌ *DDNS 错误*: 无法获取公网IP!%0A域名: \`$record_name\`%0A类型: \`$record_type\`"; return 1
}

update_record() {
  local record_type=$1 record_name=$2 wan_ip=$3; local id_file="$DATA_DIR/.cf-id_${record_name//./_}_${record_type}.txt"; local id_zone="" id_record=""
  if [[ -f "$id_file" ]]; then id_zone=$(head -1 "$id_file" 2>/dev/null); id_record=$(sed -n '2p' "$id_file" 2>/dev/null); fi
  local api_data="{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$wan_ip\", \"ttl\":$CFTTL,\"proxied\":false}"
  if [[ -n "$id_zone" && -n "$id_record" ]]; then
    log_message INFO "使用缓存 ID (Zone: $id_zone, Record: $id_record) 尝试更新 $record_name..."
    local update_response; update_response=$(curl -s -m 10 -X PUT "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records/$id_record" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" --data "$api_data")
    if [[ $(echo "$update_response" | jq -r '.success') == "true" ]]; then log_message SUCCESS "成功使用缓存ID将 $record_name 更新为 $wan_ip。"; return 0; fi
    log_message WARN "使用缓存ID更新失败，将重新查询API。错误: $(echo "$update_response" | jq -r '.errors[].message' | paste -sd ', ')"; id_zone=""; id_record=""; rm -f "$id_file"
  fi
  log_message INFO "缓存无效或不存在，正在通过 API 查询 Zone ID..."; local zone_response; zone_response=$(curl -s -m 10 -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json")
  if [[ $(echo "$zone_response" | jq -r '.success') != "true" ]]; then log_message ERROR "无法获取 Zone ID。API 错误: $(echo "$zone_response" | jq -r '.errors[].message' | paste -sd ', ')"; send_tg_notification "❌ *DDNS 错误*: 无法获取Zone ID%0A域名: \`$CFZONE_NAME\`"; return 1; fi
  id_zone=$(echo "$zone_response" | jq -r '.result[] | select(.name == "'"$CFZONE_NAME"'") | .id'); if [ -z "$id_zone" ]; then log_message ERROR "在您的账户下未找到域名区域 $CFZONE_NAME。"; return 1; fi
  log_message INFO "获取到 Zone ID: $id_zone。正在查询 Record ID for $record_name..."; local record_response; record_response=$(curl -s -m 10 -X GET "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records?name=$record_name&type=$record_type" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json"); id_record=$(echo "$record_response" | jq -r '.result[] | select(.type == "'"$record_type"'") | .id')
  if [ -z "$id_record" ]; then
    log_message INFO "找不到记录，正在为 $record_name 创建新记录..."; local create_response; create_response=$(curl -s -m 10 -X POST "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" --data "$api_data")
    if [[ $(echo "$create_response" | jq -r '.success') == "true" ]]; then id_record=$(echo "$create_response" | jq -r '.result.id'); log_message SUCCESS "成功创建记录 $record_name，IP 为 $wan_ip。"; else log_message ERROR "创建记录失败: $(echo "$create_response" | jq -r '.errors[].message' | paste -sd ', ')"; return 1; fi
  else
    log_message INFO "找到记录 ID: $id_record, 正在更新..."; local update_response_fresh; update_response_fresh=$(curl -s -m 10 -X PUT "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records/$id_record" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" --data "$api_data")
    if [[ $(echo "$update_response_fresh" | jq -r '.success') != "true" ]]; then log_message ERROR "更新 $record_name 失败: $(echo "$update_response_fresh" | jq -r '.errors[].message' | paste -sd ', ')"; return 1; fi; log_message SUCCESS "成功将 $record_name 更新为 $wan_ip。"
  fi
  log_message INFO "正在将新的 ID 写入缓存文件: $id_file"; printf "%s\n%s" "$id_zone" "$id_record" > "$id_file"; return 0
}

process_record_type() {
  local record_type=$1 record_name=$2; if [ -z "$record_name" ]; then log_message WARN "未配置 $record_type 记录的域名，跳过。"; return 0; fi
  local ip_file="$DATA_DIR/.cf-wan_ip_${record_name//./_}_${record_type}.txt"; local current_ip="" old_ip=""
  log_message INFO "正在处理 $record_name ($record_type) 记录。"; if ! current_ip=$(get_wan_ip "$record_type" "$record_name"); then return 1; fi
  if [[ -f "$ip_file" ]]; then old_ip=$(cat "$ip_file"); fi
  if [[ "$current_ip" != "$old_ip" ]] || [[ "$FORCE" == "true" ]]; then
    if [[ "$FORCE" == "true" ]]; then log_message INFO "$record_name 强制更新，当前IP: $current_ip。"; else log_message INFO "$record_name IP 已从 '${old_ip:-无}' 更改为 '$current_ip'。"; fi
    if update_record "$record_type" "$record_name" "$current_ip"; then echo "$current_ip" > "$ip_file"; send_tg_notification "✅ *DDNS 更新成功*!%0A域名: \`$record_name\`%0A新IP: \`$current_ip\`%0A旧IP: \`${old_ip:-无}\`"; else return 1; fi
  else log_message INFO "$record_name IP 地址未更改: $current_ip。"; fi
  return 0
}

run_ddns_update() {
  log_message INFO "--- 启动动态 DNS 更新过程 ---"; echo -e "${BLUE}⚡ 正在启动动态 DNS 更新...${NC}"
  if ! load_config; then log_message ERROR "找不到配置文件。"; echo -e "${RED}❌ 错误: 配置文件缺失。${NC}"; exit 1; fi
  if [[ "$ENABLE_IPV4" == "false" && "$ENABLE_IPV6" == "false" ]]; then log_message WARN "IPv4 和 IPv6 更新均已禁用。"; echo -e "${YELLOW}ℹ️ IPv4/v6 均已禁用。${NC}"; exit 0; fi
  if [[ "$ENABLE_IPV4" == "true" ]]; then process_record_type "A" "$CFRECORD_NAME_V4"; fi
  if [[ "$ENABLE_IPV6" == "true" ]]; then process_record_type "AAAA" "$CFRECORD_NAME_V6"; fi
  log_message INFO "--- 动态 DNS 更新过程完成 ---"; echo -e "${GREEN}✅ 更新过程完成。${NC}"
}

# =====================================================================
# 主程序入口
# =====================================================================
main() {
  for dep in curl grep sed jq; do if ! command -v "$dep" &>/dev/null; then echo -e "${RED}❌ 错误: 缺少依赖: ${dep}。${NC}" >&2; exit 1; fi; done
  if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}❌ 错误: 此脚本需要 root 权限运行。${NC}" >&2; exit 1; fi
  
  # 【新增】版本检测与自动更新逻辑
  local SCRIPT_VERSION; SCRIPT_VERSION=$(grep -m 1 '版本:' "$0" | awk '{print $3}')
  if [ -f "$INSTALLED_SCRIPT_PATH" ]; then
      local INSTALLED_VERSION; INSTALLED_VERSION=$(grep -m 1 '版本:' "$INSTALLED_SCRIPT_PATH" | awk '{print $3}')
      if [[ -n "$SCRIPT_VERSION" && -n "$INSTALLED_VERSION" && "$SCRIPT_VERSION" != "$INSTALLED_VERSION" ]]; then
          echo -e "${YELLOW}检测到新版本！${NC}"
          echo -e "  当前运行版本: ${CYAN}$SCRIPT_VERSION${NC}"
          echo -e "  系统中已安装版本:   ${PURPLE}$INSTALLED_VERSION${NC}"
          read -p "$(echo -e "${GREEN}是否要立即更新已安装的脚本? [Y/n]: ${NC}")" confirm_update
          if [[ ! "${confirm_update,,}" =~ ^n$ ]]; then
              perform_update "$0" "$INSTALLED_SCRIPT_PATH" "$@"
          fi
      fi
  fi
  
  init_dirs
  if [ $# -gt 0 ]; then
    case "$1" in update) run_ddns_update; exit 0 ;; uninstall) uninstall_ddns; exit 0 ;; *) echo -e "${RED}❌ 无效参数: ${1}${NC}"; exit 1 ;; esac
  fi
  while true; do
    show_main_menu
    case $main_choice in
      1) install_ddns ;; 2) modify_config ;; 3) clear; show_current_config; read -p "按回车键返回..." ;;
      4) run_ddns_update; read -p "按回车键返回..." ;; 5) manage_cron_job ;; 6) view_logs ;;
      7) uninstall_ddns ;; 8) echo -e "${GREEN}👋 退出脚本。${NC}"; exit 0 ;;
      *) echo -e "${RED}❌ 无效选项。${NC}"; sleep 2 ;;
    esac
  done
}

# 执行主函数
main "$@"
