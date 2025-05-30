#!/usr/bin/env bash
# 设置严格的错误处理机制
set -o errexit  # 任何命令失败时立即退出
set -o nounset  # 使用未定义变量时报错
set -o pipefail # 管道中任何命令失败时整个管道失败

# 配置存储目录
CONFIG_DIR="/etc/cf-ddns"
# 数据存储目录
DATA_DIR="/var/lib/cf-ddns"
# 配置文件路径
CONFIG_FILE="$CONFIG_DIR/config.conf"
# 日志文件路径
LOG_FILE="/var/log/cf-ddns.log"
# 定时任务标识
CRON_JOB_ID="CLOUDFLARE_DDNS_JOB"

# 默认配置参数
CFKEY=""               # Cloudflare API密钥
CFUSER=""              # Cloudflare账户邮箱
CFZONE_NAME=""         # 域名区域 (如：example.com)
CFRECORD_NAME=""       # 完整记录名称 (如：host.example.com)
CFRECORD_TYPE="BOTH"   # 记录类型：A(IPv4)|AAAA(IPv6)|BOTH(双栈)
CFTTL=120              # DNS记录TTL值 (120-86400秒)
FORCE=false            # 强制更新模式 (忽略本地IP缓存)
TG_BOT_TOKEN=""        # Telegram机器人Token
TG_CHAT_ID=""          # Telegram聊天ID

# 公网IP检测服务 (多源冗余)
WANIPSITE_v4=(
  "http://ipv4.icanhazip.com"
  "http://api.ipify.org"
  "http://ident.me"
)
WANIPSITE_v6=(
  "http://ipv6.icanhazip.com"
  "http://v6.ident.me"
  "http://api6.ipify.org"
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# =====================================================================
# 函数：显示主菜单
# =====================================================================
show_main_menu() {
  clear
  echo -e "${YELLOW}=============================================="
  echo " CloudFlare DDNS 管理脚本 "
  echo "=============================================="
  echo " 1. 安装并配置DDNS"
  echo " 2. 修改DDNS配置"
  echo " 3. 卸载DDNS"
  echo " 4. 查看当前配置"
  echo " 5. 手动运行更新"
  echo " 6. 查看日志"
  echo " 7. 配置Telegram通知"
  echo " 8. 退出脚本"
  echo -e "==============================================${NC}"
  echo 
  read -p "请输入选项 [1-8]: " main_choice
}

# =====================================================================
# 函数：初始化目录结构
# =====================================================================
init_dirs() {
  # 创建配置目录
  if [ ! -d "$CONFIG_DIR" ]; then
    echo -e "${BLUE}创建配置目录: $CONFIG_DIR${NC}"
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
  fi
  
  # 创建数据目录
  if [ ! -d "$DATA_DIR" ]; then
    echo -e "${BLUE}创建数据目录: $DATA_DIR${NC}"
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
  fi
  
  # 创建日志文件
  if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    echo -e "${BLUE}创建日志文件: $LOG_FILE${NC}"
  fi
}

# =====================================================================
# 函数：交互式配置向导
# =====================================================================
interactive_config() {
  echo
  echo -e "${YELLOW}=============================================="
  echo " CloudFlare DDNS 配置向导"
  echo -e "==============================================${NC}"
  
  # API密钥
  while :; do
    read -p "请输入Cloudflare API密钥: " CFKEY
    if [ -z "$CFKEY" ]; then
      echo -e "${RED}错误: API密钥不能为空!${NC}"
    elif [[ "$CFKEY" =~ ^[a-zA-Z0-9]{37}$ ]]; then
      break
    else
      echo -e "${RED}错误: API密钥格式无效 (应为37位字母数字组合)${NC}"
    fi
  done
  
  # 用户邮箱
  while :; do
    read -p "请输入Cloudflare账户邮箱: " CFUSER
    if [ -z "$CFUSER" ]; then
      echo -e "${RED}错误: 账户邮箱不能为空!${NC}"
    elif [[ "$CFUSER" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      echo -e "${RED}错误: 邮箱格式无效!${NC}"
    fi
  done
  
  # 区域名称
  while :; do
    read -p "请输入域名区域 (如: example.com): " CFZONE_NAME
    if [ -z "$CFZONE_NAME" ]; then
      echo -e "${RED}错误: 域名区域不能为空!${NC}"
    elif [[ "$CFZONE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      echo -e "${RED}错误: 域名格式无效!${NC}"
    fi
  done
  
  # 记录名称
  while :; do
    read -p "请输入主机记录 (如: home 或 host.example.com): " CFRECORD_NAME
    if [ -z "$CFRECORD_NAME" ]; then
      echo -e "${RED}错误: 主机记录不能为空!${NC}"
    else
      # 自动补全FQDN格式
      if [[ "$CFRECORD_NAME" != *"$CFZONE_NAME" ]]; then
        CFRECORD_NAME="${CFRECORD_NAME}.${CFZONE_NAME}"
        echo -e "${GREEN}提示: 自动补全为完整域名: $CFRECORD_NAME${NC}"
      fi
      
      # 验证域名格式
      if [[ "$CFRECORD_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        break
      else
        echo -e "${RED}错误: 主机记录格式无效!${NC}"
      fi
    fi
  done
  
  # 记录类型
  while :; do
    echo -e "${BLUE}请选择记录类型:${NC}"
    echo "1) IPv4 (A记录)"
    echo "2) IPv6 (AAAA记录)"
    echo "3) 双栈 (A和AAAA记录)"
    read -p "请输入选项 [1-3] (默认3): " type_choice
    case ${type_choice:-3} in
      1) CFRECORD_TYPE="A"; break ;;
      2) CFRECORD_TYPE="AAAA"; break ;;
      3) CFRECORD_TYPE="BOTH"; break ;;
      *) echo -e "${RED}无效选择，请重新输入!${NC}" ;;
    esac
  done
  
  # TTL设置
  while :; do
    read -p "请输入TTL值 (120-86400, 默认120): " ttl_input
    if [ -z "$ttl_input" ]; then
      break
    elif [[ "$ttl_input" =~ ^[0-9]+$ ]] && [ "$ttl_input" -ge 120 ] && [ "$ttl_input" -le 86400 ]; then
      CFTTL="$ttl_input"
      break
    else
      echo -e "${RED}错误: TTL值必须是120-86400之间的整数!${NC}"
    fi
  done
  
  # 保存配置
  save_config
  
  echo
  echo -e "${GREEN}配置已保存到: $CONFIG_FILE${NC}"
  echo -e "${YELLOW}=============================================="
  echo -e "${NC}"
}

# =====================================================================
# 函数：发送Telegram通知
# =====================================================================
send_tg_notification() {
  local message="$1"
  
  # 检查是否配置了Telegram通知
  if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    echo "[Telegram] 未配置通知功能，跳过发送" >> "$LOG_FILE"
    return 0
  fi
  
  # 发送通知
  local response=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=Markdown")
  
  # 检查发送结果
  if [[ "$response" == *"\"ok\":true"* ]]; then
    echo "[Telegram] 通知发送成功" >> "$LOG_FILE"
    return 0
  else
    echo "[Telegram] 错误: 通知发送失败 - $response" >> "$LOG_FILE"
    return 1
  fi
}

# =====================================================================
# 函数：配置Telegram通知
# =====================================================================
configure_telegram() {
  echo
  echo -e "${YELLOW}=============================================="
  echo " Telegram通知配置"
  echo -e "==============================================${NC}"
  
  # 加载现有配置
  load_config || true
  
  # 显示当前配置
  if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    echo -e "${GREEN}当前已配置Telegram通知功能${NC}"
    echo "机器人Token: ${TG_BOT_TOKEN:0:4}****${TG_BOT_TOKEN: -4}"
    echo "聊天ID: $TG_CHAT_ID"
    echo
    read -p "是否重新配置? [y/N]: " reconfigure
    if [[ ! "${reconfigure,,}" =~ ^y$ ]]; then
      return 0
    fi
  fi
  
  # 询问是否启用通知
  read -p "是否启用Telegram通知? [Y/n]: " enable_tg
  if [[ "${enable_tg,,}" =~ ^n$ ]]; then
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    save_config
    echo -e "${YELLOW}已禁用Telegram通知功能${NC}"
    return 0
  fi
  
  # 获取Telegram Bot Token
  while :; do
    read -p "请输入Telegram Bot Token: " TG_BOT_TOKEN
    if [ -z "$TG_BOT_TOKEN" ]; then
      echo -e "${RED}错误: Token不能为空!${NC}"
    elif [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
      break
    else
      echo -e "${RED}错误: Token格式无效!${NC}"
    fi
  done
  
  # 获取Telegram Chat ID
  while :; do
    read -p "请输入Telegram Chat ID: " TG_CHAT_ID
    if [ -z "$TG_CHAT_ID" ]; then
      echo -e "${RED}错误: Chat ID不能为空!${NC}"
    elif [[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
      break
    else
      echo -e "${RED}错误: Chat ID必须是数字!${NC}"
    fi
  done
  
  # 保存配置
  save_config
  
  # 发送测试消息
  echo -e "${BLUE}发送测试消息...${NC}"
  if send_tg_notification "🔔 *Cloudflare DDNS 测试通知*  
  ✅ Telegram通知配置成功！
  域名: \`$CFRECORD_NAME\`
  记录类型: \`$CFRECORD_TYPE\`
  时间: $(date +"%Y-%m-%d %H:%M:%S")"; then
    echo -e "${GREEN}测试消息发送成功! 请检查Telegram${NC}"
  else
    echo -e "${RED}测试消息发送失败! 请检查配置${NC}"
  fi
  
  echo -e "${GREEN}Telegram通知配置已保存${NC}"
}



# =====================================================================
# 函数：保存配置到文件
# =====================================================================
save_config() {
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
    echo "TG_BOT_TOKEN='$TG_BOT_TOKEN"
    echo "TG_CHAT_ID='$TG_CHAT_ID"
  } > "$CONFIG_FILE"
  
  chmod 600 "$CONFIG_FILE"
}

# =====================================================================
# 函数：加载配置文件
# =====================================================================
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # 安全地加载配置文件
    source "$CONFIG_FILE" >/dev/null 2>&1
    return 0
  fi
  return 1
}

# =====================================================================
# 函数：添加定时任务
# =====================================================================
add_cron_job() {
  # 获取脚本绝对路径
  local script_path="$(realpath "$0")"
  
  # 检查是否已存在定时任务
  if crontab -l 2>/dev/null | grep -q "$CRON_JOB_ID"; then
    echo -e "${YELLOW}定时任务已存在，更新配置${NC}"
    remove_cron_job
  fi
  
  # 添加定时任务
  (
    crontab -l 2>/dev/null
    echo "# $CRON_JOB_ID"
    echo "*/2 * * * * $script_path update >> '$LOG_FILE' 2>&1"
  ) | crontab -
  
  echo -e "${GREEN}已添加定时任务: 每2分钟运行一次${NC}"
  echo -e "日志文件: $LOG_FILE"
}

# =====================================================================
# 函数：移除定时任务
# =====================================================================
remove_cron_job() {
  # 删除定时任务
  crontab -l | grep -v "$CRON_JOB_ID" | crontab - 2>/dev/null
  echo -e "${GREEN}已移除定时任务${NC}"
}

# =====================================================================
# 函数：卸载DDNS
# =====================================================================
uninstall_ddns() {
  echo -e "${YELLOW}开始卸载DDNS...${NC}"
  
  # 移除定时任务
  remove_cron_job
  
  # 删除系统路径下的脚本
  if [ -f "/usr/local/bin/cf-ddns" ]; then
    rm -f "/usr/local/bin/cf-ddns"
    echo -e "${GREEN}已删除系统路径下的脚本: /usr/local/bin/cf-ddns${NC}"
  fi
  
  # 删除快捷键链接
  if [ -f "/usr/local/bin/d" ]; then
    rm -f "/usr/local/bin/d"
    echo -e "${GREEN}已删除快捷键链接: /usr/local/bin/d${NC}"
  fi
  
  # 询问是否删除配置文件
  read -p "是否删除所有配置文件? [y/N]: " delete_choice
  if [[ "${delete_choice,,}" =~ ^y$ ]]; then
    echo -e "${BLUE}删除配置目录: $CONFIG_DIR${NC}"
    rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}配置文件已删除${NC}"
    
    # 询问是否删除数据文件
    read -p "是否删除所有数据文件? [y/N]: " delete_data_choice
    if [[ "${delete_data_choice,,}" =~ ^y$ ]]; then
      echo -e "${BLUE}删除数据目录: $DATA_DIR${NC}"
      rm -rf "$DATA_DIR"
      echo -e "${GREEN}数据文件已删除${NC}"
    else
      echo -e "${YELLOW}数据文件保留在 $DATA_DIR${NC}"
    fi
    
    # 询问是否删除日志文件
    read -p "是否删除日志文件? [y/N]: " delete_log_choice
    if [[ "${delete_log_choice,,}" =~ ^y$ ]]; then
      echo -e "${BLUE}删除日志文件: $LOG_FILE${NC}"
      rm -f "$LOG_FILE"
      echo -e "${GREEN}日志文件已删除${NC}"
    else
      echo -e "${YELLOW}日志文件保留在 $LOG_FILE${NC}"
    fi
  else
    echo -e "${YELLOW}配置文件保留在 $CONFIG_DIR${NC}"
    echo -e "${YELLOW}数据文件保留在 $DATA_DIR${NC}"
    echo -e "${YELLOW}日志文件保留在 $LOG_FILE${NC}"
  fi
  
  # 询问是否删除脚本自身
  read -p "是否删除此脚本文件? [y/N]: " delete_script_choice
  if [[ "${delete_script_choice,,}" =~ ^y$ ]]; then
    script_self="$(realpath "$0")"
    echo -e "${BLUE}正在删除脚本自身...${NC}"
    rm -f "$script_self"
    echo -e "${GREEN}脚本已删除${NC}"
    echo -e "${GREEN}DDNS卸载完成${NC}"
    exit 0  # 删除后立即退出
  else
    echo -e "${YELLOW}脚本文件保留: $(realpath "$0")${NC}"
  fi
  
  echo -e "${GREEN}DDNS卸载完成${NC}"
}


# =====================================================================
# 函数：获取当前公网IP地址 (多源冗余)
# =====================================================================
get_wan_ip() {
  local record_type=$1
  local ip_sources=()
  local ip=""
  
  if [[ "$record_type" == "A" ]]; then
    ip_sources=("${WANIPSITE_v4[@]}")
  else
    ip_sources=("${WANIPSITE_v6[@]}")
  fi
  
  # 尝试多个IP源直到成功
  for source in "${ip_sources[@]}"; do
    echo "[IP检测] 尝试源: $source" >> "$LOG_FILE"
    ip=$(curl -s --connect-timeout 5 "$source" | tr -d '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([a-f0-9]{1,4}:){7}[a-f0-9]{1,4}')
    
    if [[ -n "$ip" ]]; then
      echo "[IP检测] 成功获取IP: $ip" >> "$LOG_FILE"
      echo "$ip"
      return 0
    fi
  done
  
  echo "[IP检测] 错误: 所有源均无法获取IP" >> "$LOG_FILE"
  
  # 发送Telegram通知
  local message="❌ *Cloudflare DDNS 错误*  
  🔍 无法获取公网IP地址！
  记录类型: \`$record_type\`
  域名: \`$CFRECORD_NAME\`
  时间: $(date +"%Y-%m-%d %H:%M:%S")
  ⚠️ 请检查网络连接或IP检测服务"
  
  send_tg_notification "$message"
  
  return 1
}

# =====================================================================
# 函数：更新DNS记录 (带重试机制和自动创建记录)
# =====================================================================
update_record() {
  local record_type=$1
  local record_name=$2
  local wan_ip=$3
  local retries=3
  local delay=5
  
  # 构造ID存储文件名 (按记录类型区分)
  local id_file="$DATA_DIR/.cf-id_${record_name//./_}_${record_type}.txt"
  local id_zone=""
  local id_record=""
  
  # 检查ID文件是否存在
  if [[ -f "$id_file" ]]; then
    # 从现有文件读取区域ID和记录ID
    id_zone=$(head -1 "$id_file")
    id_record=$(sed -n '2p' "$id_file")
  else
    echo "[$record_type] 创建新的ID存储文件: $id_file" >> "$LOG_FILE"
  fi
  
  # 获取区域ID (Zone ID) - 如果尚未获取
  if [ -z "$id_zone" ]; then
    for ((i=1; i<=retries; i++)); do
      id_zone=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
      
      if [ -n "$id_zone" ]; then
        break
      else
        echo "[$record_type] 获取区域ID失败 (尝试 $i/$retries)" >> "$LOG_FILE"
        sleep $delay
      fi
    done
    
    # 检查是否成功获取区域ID
    if [ -z "$id_zone" ]; then
      echo "[$record_type] 错误: 无法获取区域ID" >> "$LOG_FILE"
      return 1
    fi
  fi
  
  # 获取记录ID (Record ID) - 如果尚未获取
  if [ -z "$id_record" ]; then
    for ((i=1; i<=retries; i++)); do
      id_record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records?name=$record_name&type=$record_type" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
      
      if [ -n "$id_record" ]; then
        break
      else
        echo "[$record_type] 获取记录ID失败 (尝试 $i/$retries)" >> "$LOG_FILE"
        sleep $delay
      fi
    done
  fi
  
  # 如果记录不存在，则创建新记录
  if [ -z "$id_record" ]; then
    echo "[$record_type] 记录不存在，正在创建新记录: $record_name" >> "$LOG_FILE"
    
    for ((i=1; i<=retries; i++)); do
      local create_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$wan_ip\", \"ttl\":$CFTTL}")
      
      if [[ "$create_response" == *"\"success\":true"* ]]; then
        id_record=$(echo "$create_response" | grep -Po '(?<="id":")[^"]*' | head -1)
        echo "[$record_type] 记录创建成功! 记录ID: $id_record" >> "$LOG_FILE"
        break
      else
        echo "[$record_type] 记录创建失败! API响应: $create_response" >> "$LOG_FILE"
        sleep $delay
      fi
    done
    
    # 检查是否成功创建记录
    if [ -z "$id_record" ]; then
      echo "[$record_type] 错误: 无法创建新记录" >> "$LOG_FILE"
      return 1
    fi
  fi
  
  # 保存ID到文件 (无论新创建还是已存在)
  printf "%s\n%s" "$id_zone" "$id_record" > "$id_file"
  echo "[$record_type] 区域ID和记录ID已保存" >> "$LOG_FILE"
  
  # 更新DNS记录 (带重试)
  for ((i=1; i<=retries; i++)); do
    echo "[$record_type] 正在更新 $record_name 记录到 $wan_ip (尝试 $i/$retries)" >> "$LOG_FILE"
    local response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$id_zone/dns_records/$id_record" \
      -H "X-Auth-Email: $CFUSER" \
      -H "X-Auth-Key: $CFKEY" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$wan_ip\", \"ttl\":$CFTTL}")
    
    # 检查API响应
    if [[ "$response" == *"\"success\":true"* ]]; then
      echo "[$record_type] 更新成功!" >> "$LOG_FILE"
      return 0
    else
      echo "[$record_type] 更新失败! API响应: $response" >> "$LOG_FILE"
      sleep $delay
    fi
  done
  
  # 如果重试后仍然失败
  local message="❌ *Cloudflare DDNS 更新失败*  
  🔍 记录类型: \`$record_type\`
  域名: \`$record_name\`
  尝试次数: $retries
  时间: $(date +"%Y-%m-%d %H:%M:%S")
  ⚠️ 请检查日志获取详细信息"
  
  send_tg_notification "$message"
  
  return 1
}
 
# =====================================================================
# 函数：处理单个记录类型的更新流程
# =====================================================================
process_record_type() {
  local record_type=$1
  # 构造IP存储文件名 (按记录类型区分)
  local ip_file="$DATA_DIR/.cf-wan_ip_${CFRECORD_NAME//./_}_${record_type}.txt"
  local current_ip=""
  local old_ip=""
  
  # 获取当前公网IP
  if ! current_ip=$(get_wan_ip "$record_type"); then
    echo "[$record_type] 错误: 无法获取公网IP地址" >> "$LOG_FILE"
    return 1
  fi
  
  # 读取上次存储的IP
  [[ -f "$ip_file" ]] && old_ip=$(cat "$ip_file")
  
  # 检查是否需要更新
  if [[ "$current_ip" != "$old_ip" ]] || [[ "$FORCE" == "true" ]]; then
    echo "[$record_type] 检测到IP变更: ${old_ip:-无} -> $current_ip" >> "$LOG_FILE"
    # 调用更新函数
    if update_record "$record_type" "$CFRECORD_NAME" "$current_ip"; then
      # 更新成功后保存新IP
      echo "$current_ip" > "$ip_file"
      echo "[$record_type] 新IP已保存" >> "$LOG_FILE"
      # 发送成功通知
      local message="✅ *Cloudflare DDNS 更新成功*  
      记录类型: \`$record_type\`
      域名: \`$CFRECORD_NAME\`
      新IP: \`$current_ip\`
      旧IP: \`${old_ip:-无}\`
      时间: $(date +"%Y-%m-%d %H:%M:%S")"
      send_tg_notification "$message"
    else
      echo "[$record_type] 错误: 更新失败" >> "$LOG_FILE"
      return 1
    fi
  else
    echo "[$record_type] IP地址未变化: $current_ip" >> "$LOG_FILE"
  fi
  return 0
}

# =====================================================================
# 函数：执行DDNS更新
# =====================================================================
run_ddns_update() {
  # 记录执行开始
  echo "==========================================================" >> "$LOG_FILE"
  echo "$(date) - 开始执行动态DNS更新" >> "$LOG_FILE"
  
  # 加载配置文件
  if ! load_config; then
    echo "错误: 配置文件不存在!" >> "$LOG_FILE"
    exit 1
  fi
  
  # 验证配置
  if [[ -z "$CFKEY" || -z "$CFUSER" || -z "$CFZONE_NAME" || -z "$CFRECORD_NAME" ]]; then
    echo "错误: 配置文件不完整!" >> "$LOG_FILE"
    exit 1
  fi
  
  # 根据记录类型处理更新
  case "$CFRECORD_TYPE" in
    "A"|"AAAA")
      # 处理单个记录类型 (IPv4或IPv6)
      if ! process_record_type "$CFRECORD_TYPE"; then
        echo "错误: $CFRECORD_TYPE 记录更新失败" >> "$LOG_FILE"
      fi
      ;;
    "BOTH")
      # 处理双栈记录 (IPv4和IPv6)
      if ! process_record_type "A"; then
        echo "错误: A记录更新失败" >> "$LOG_FILE"
      fi
      if ! process_record_type "AAAA"; then
        echo "错误: AAAA记录更新失败" >> "$LOG_FILE"
      fi
      ;;
    *)
      # 无效记录类型处理
      echo "错误: 无效的记录类型 '$CFRECORD_TYPE' (必须是 A, AAAA 或 BOTH)" >> "$LOG_FILE"
      exit 2
      ;;
  esac
  
  # 记录执行完成
  echo "$(date) - 动态DNS更新完成" >> "$LOG_FILE"
  echo "==========================================================" >> "$LOG_FILE"
}

# =====================================================================
# 函数：安装DDNS
# =====================================================================
install_ddns() {
  echo -e "${YELLOW}开始安装DDNS...${NC}"
  
  # 初始化目录结构
  init_dirs
  
  # 运行配置向导
  interactive_config
  
  # 添加定时任务
  add_cron_job
  
  # 复制脚本到系统路径
  echo -e "${BLUE}正在安装脚本到系统路径...${NC}"
  script_path=$(realpath "$0")
  cp -f "$script_path" /usr/local/bin/cf-ddns
  chmod 755 /usr/local/bin/cf-ddns
  
  # 添加快捷键链接 (d)
  if [ ! -f "/usr/local/bin/d" ]; then
    ln -s /usr/local/bin/cf-ddns /usr/local/bin/d
    echo -e "${GREEN}已创建快捷键: 输入 'd' 即可启动脚本${NC}"
  fi
  
  echo -e "${GREEN}已将脚本安装到系统路径: /usr/local/bin/cf-ddns${NC}"
  
  # 立即运行一次更新
  echo -e "${GREEN}正在运行首次更新...${NC}"
  run_ddns_update
  echo -e "${GREEN}首次更新完成!${NC}"
  
  echo -e "${YELLOW}=============================================="
  echo -e " 安装完成! 您可以使用以下命令:"
  echo -e "  - 输入 'd' 快速启动管理菜单"
  echo -e "  - 输入 'cf-ddns' 启动管理菜单"
  echo -e "  - 输入 'cf-ddns update' 手动更新DNS记录"
  echo -e "==============================================${NC}"
}

# =====================================================================
# 函数：修改配置
# =====================================================================
modify_config() {
  echo -e "${YELLOW}开始修改配置...${NC}"
  
  # 加载现有配置
  if ! load_config; then
    echo -e "${RED}错误: 没有找到现有配置${NC}"
    echo -e "请先安装DDNS"
    return 1
  fi
  
  # 备份旧配置
  local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$backup_file"
  echo -e "${BLUE}旧配置已备份到: $backup_file${NC}"
  
  # 显示当前配置
  show_current_config
  
  # 运行配置向导
  interactive_config
  
  # 添加定时任务
  add_cron_job
  
  echo -e "${GREEN}配置修改完成!${NC}"
}

# =====================================================================
# 函数：显示当前配置
# =====================================================================
show_current_config() {
  if load_config; then
    echo -e "${YELLOW}当前配置:${NC}"
    echo "----------------------------"
    echo "API密钥: ${CFKEY:0:4}****${CFKEY: -4}"
    echo "账户邮箱: $CFUSER"
    echo "域名区域: $CFZONE_NAME"
    echo "主机记录: $CFRECORD_NAME"
    echo "记录类型: $CFRECORD_TYPE"
    echo "TTL值: $CFTTL"
    echo "----------------------------"
  else
    echo -e "${RED}未找到有效配置${NC}"
  fi
}

# =====================================================================
# 函数：查看日志
# =====================================================================
view_logs() {
  if [ -f "$LOG_FILE" ]; then
    echo -e "${YELLOW}显示最后20行日志:${NC}"
    echo "----------------------------------------"
    tail -n 20 "$LOG_FILE"
    echo "----------------------------------------"
    echo -e "完整日志路径: $LOG_FILE"
  else
    echo -e "${RED}日志文件不存在${NC}"
  fi
}

# =====================================================================
# 主程序入口
# =====================================================================

# 检查是否以root运行
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}错误: 此脚本需要root权限运行${NC}"
  exit 1
fi

# 处理命令行参数
if [ $# -gt 0 ]; then
  case "$1" in
    update)
      run_ddns_update
      exit 0
      ;;
    install)
      install_ddns
      exit 0
      ;;
    modify)
      modify_config
      exit 0
      ;;
    uninstall)
      uninstall_ddns
      exit 0
      ;;
    *)
      echo "无效参数: $1"
      echo "可用参数: update, install, modify, uninstall"
      exit 1
      ;;
  esac
fi

# 显示主菜单
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
      read -p "按回车键返回主菜单..."
      ;;
    4)
      show_current_config
      read -p "按回车键返回主菜单..."
      ;;
    5)
      echo -e "${YELLOW}手动运行更新...${NC}"
      run_ddns_update
      echo -e "${GREEN}更新完成! 查看日志获取详情${NC}"
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
      echo -e "${GREEN}退出脚本${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}无效选项，请重新输入${NC}"
      sleep 2
      ;;
  esac
done
