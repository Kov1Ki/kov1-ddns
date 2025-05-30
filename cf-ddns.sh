#!/usr/bin/env bash
# CloudFlare DDNS 管理脚本


set -o errexit
set -o nounset
set -o pipefail

# 配置存储目录
CONFIG_DIR="/etc/cf-ddns"
# 数据存储目录
DATA_DIR="/var/lib/cf-ddns"
# 日志存储目录
LOG_DIR="/var/log/cf-ddns"
# 配置文件路径
CONFIG_FILE="$CONFIG_DIR/config.conf"
# 日志文件路径
LOG_FILE="$LOG_DIR/cf-ddns.log"
# 定时任务标识
CRON_JOB_ID="CLOUDFLARE_DDNS_JOB"

# 默认配置参数
CFKEY=""               # Cloudflare API密钥
CFUSER=""              # Cloudflare账户邮箱
CFZONE_NAME=""         # 域名区域 (如：example.com)
CFRECORD_NAME=""       # 完整记录名称 (如：host.example.com)
CFRECORD_TYPE="BOTH"   # 记录类型：A|AAAA|BOTH
CFTTL=120              # DNS记录TTL值 (120-86400秒)
FORCE_UPDATE=false     # 强制更新模式
TG_BOT_TOKEN=""        # Telegram机器人Token
TG_CHAT_ID=""          # Telegram聊天ID

# 公网IP检测服务 (多源冗余)
WANIPSITE_V4=(
  "https://ipv4.icanhazip.com"
  "https://api.ipify.org"
  "https://ident.me"
)
WANIPSITE_V6=(
  "https://ipv6.icanhazip.com"
  "https://v6.ident.me"
  "https://api6.ipify.org"
)

# 颜色定义
declare -A COLORS=(
  [RED]='\033[0;31m'
  [GREEN]='\033[0;32m'
  [YELLOW]='\033[1;33m'
  [BLUE]='\033[0;34m'
  [NC]='\033[0m' # 恢复默认颜色
)

# 依赖检查
dependencies=(curl jq openssl)
for dep in "${dependencies[@]}"; do
  if ! command -v "$dep" &> /dev/null; then
    echo -e "${COLORS[RED]}错误: 缺少依赖 $dep${COLORS[NC]}" >&2
    exit 1
  fi
done

# 信号处理
trap 'echo -e "\n${COLORS[RED]}收到中断信号，正在退出...${COLORS[NC]}"; exit 1' SIGINT SIGTERM

# =====================================================================
# 核心功能函数
# =====================================================================

# 获取当前公网IP地址 (多源冗余)
get_wan_ip() {
  local record_type=$1
  local ip_sources=()
  local ip=""
  
  [[ "$record_type" == "A" ]] && ip_sources=("${WANIPSITE_V4[@]}")
  [[ "$record_type" == "AAAA" ]] && ip_sources=("${WANIPSITE_V6[@]}")
  
  for source in "${ip_sources[@]}"; do
    for ((retry=1; retry<=3; retry++)); do
      ip=$(curl -sS --connect-timeout 10 "$source" 2>/dev/null | tr -d '\n')
      [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
      [[ "$ip" =~ ^([a-f0-9:]+:+)+[a-f0-9]+$ ]] && break
      sleep 2
    done
    [[ -n "$ip" ]] && break
  done
  
  echo "$ip"
}

# Cloudflare API 请求封装
cloudflare_api() {
  local endpoint=$1
  local method=$2
  local data=$3
  local attempt=0
  
  while true; do
    local response=$(curl -sS -X "$method" \
      -H "X-Auth-Email: $CFUSER" \
      -H "X-Auth-Key: $CFKEY" \
      -H "Content-Type: application/json" \
      "$endpoint")
    
    if [[ "$response" == *"\"success\":true"* ]]; then
      echo "$response"
      return 0
    elif [[ "$response" == *"\"code\":10000"* ]]; then
      echo -e "${COLORS[RED]}Cloudflare API错误: $response${COLORS[NC]}" >&2
      return 1
    elif ((attempt++ >= 3)); then
      echo -e "${COLORS[RED]}请求失败超过最大重试次数${COLORS[NC]}" >&2
      return 1
    fi
    sleep $((2**attempt))
  done
}

# =====================================================================
# 用户交互函数
# =====================================================================

# 交互式配置向导
interactive_config() {
  local config=()
  
  # 获取API密钥
  while true; do
    read -rsp "请输入Cloudflare API密钥: " CFKEY
    echo
    if [[ ${#CFKEY} -eq 40 && "$CFKEY" =~ ^[a-zA-Z0-9]+$ ]]; then
      config+=("CFKEY=\"$CFKEY\"")
      break
    else
      echo -e "${COLORS[RED]}错误: 无效的API密钥（必须40位字母数字）${COLORS[NC]}"
    fi
  done
  
  # 获取邮箱
  while true; do
    read -rp "请输入Cloudflare账户邮箱: " CFUSER
    echo
    if [[ "$CFUSER" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      config+=("CFUSER=\"$CFUSER\"")
      break
    else
      echo -e "${COLORS[RED]}错误: 无效的邮箱地址${COLORS[NC]}"
    fi
  done
  
  # 获取域名区域
  while true; do
    read -rp "请输入域名区域 (如: example.com): " CFZONE_NAME
    echo
    if [[ "$CFZONE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      config+=("CFZONE_NAME=\"$CFZONE_NAME\"")
      break
    else
      echo -e "${COLORS[RED]}错误: 无效的域名区域${COLORS[NC]}"
    fi
  done
  
  # 获取记录名称
  while true; do
    read -rp "请输入主机记录 (如: home 或 host.example.com): " CFRECORD_NAME
    echo
    if [[ "$CFRECORD_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      config+=("CFRECORD_NAME=\"$CFRECORD_NAME\"")
      break
    else
      echo -e "${COLORS[RED]}错误: 无效的记录名称${COLORS[NC]}"
    fi
  done
  
  # 获取记录类型
  while true; do
    echo -e "${COLORS[BLUE]}选择记录类型:${COLORS[NC]}"
    echo "1) IPv4 (A记录)"
    echo "2) IPv6 (AAAA记录)"
    echo "3) 双栈 (A+AAAA)"
    read -rp "请输入选项 [1-3] (默认3): " choice
    case $choice in
      1) config+=("CFRECORD_TYPE=\"A\""); break ;;
      2) config+=("CFRECORD_TYPE=\"AAAA\""); break ;;
      3|*) config+=("CFRECORD_TYPE=\"BOTH\""); break ;;
    esac
  done
  
  # 获取TTL值
  while true; do
    read -rp "请输入TTL值 (120-86400, 默认120): " ttl
    if [[ -z "$ttl" || "$ttl" =~ ^[0-9]+$ && "$ttl" -ge 120 && "$ttl" -le 86400 ]]; then
      config+=("CFTTL=\"$ttl\"")
      break
    else
      echo -e "${COLORS[RED]}错误: TTL必须是120-86400的整数${COLORS[NC]}"
    fi
  done
  
  # 保存配置
  write_config "${config[@]}"
}

# 写入配置文件
write_config() {
  local config=("$@")
  local content="# CloudFlare DDNS 配置文件\n"
  content+="# 生成时间: $(date)\n\n"
  
  for item in "${config[@]}"; do
    content+="$item\n"
  done
  
  mkdir -p "$CONFIG_DIR"
  echo -e "$content" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

# 加载配置文件
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${COLORS[RED]}错误: 配置文件不存在${COLORS[NC]}" >&2
    exit 1
  fi
  
  source "$CONFIG_FILE"
}

# =====================================================================
# 系统集成函数
# =====================================================================

# 添加系统服务
add_systemd_service() {
  local service_content="[Unit]
Description=CloudFlare Dynamic DNS Updater
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/cf-ddns update
Restart=always

[Install]
WantedBy=multi-user.target"

  sudo bash -c "echo '$service_content' > /etc/systemd/system/cf-ddns.service"
  sudo systemctl daemon-reload
  sudo systemctl enable cf-ddns
  sudo systemctl start cf-ddns
}

# 创建系统快捷方式
create_system_alias() {
  sudo ln -sf /usr/local/bin/cf-ddns /usr/local/bin/ddns
}

# =====================================================================
# 主程序入口
# =====================================================================

main_menu() {
  clear
  echo -e "${COLORS[YELLOW]}=============================================="
  echo " CloudFlare DDNS 管理系统 ${COLORS[NC]}"
  echo "=============================================="
  echo " 1. 安装系统服务"
  echo " 2. 手动更新DNS"
  echo " 3. 查看运行日志"
  echo " 4. 管理配置"
  echo " 5. 卸载服务"
  echo " 6. 退出程序"
  echo -e "==============================================${COLORS[NC]}"
  read -rp "请选择操作 [1-6]: " choice
}

# 安装流程
install_systemd() {
  check_root
  interactive_config
  write_config
  add_systemd_service
  create_system_alias
  echo -e "${COLORS[GREEN]}系统服务安装完成！${COLORS[NC]}"
}

# 卸载流程
uninstall_systemd() {
  check_root
  sudo systemctl stop cf-ddns
  sudo systemctl disable cf-ddns
  sudo rm -f /etc/systemd/system/cf-ddns.service
  sudo rm -f /usr/local/bin/ddns
  echo -e "${COLORS[GREEN]}系统服务已卸载${COLORS[NC]}"
}

# 检查root权限
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${COLORS[RED]}错误: 需要root权限执行${COLORS[NC]}" >&2
    exit 1
  fi
}

# 日志查看器
view_logs() {
  tail -fn 20 "$LOG_FILE"
}

# 配置管理
manage_config() {
  local action
  while true; do
    echo -e "${COLORS[BLUE]}配置管理菜单:${COLORS[NC]}"
    echo "1. 查看当前配置"
    echo "2. 修改配置"
    echo "3. 返回上级菜单"
    read -rp "选择操作 [1-3]: " action
    
    case $action in
      1) load_config; cat "$CONFIG_FILE" | sed 's/^/    /';;
      2) interactive_config;;
      3) break;;
      *) echo -e "${COLORS[RED]}无效选项${COLORS[NC]}";;
    esac
  done
}

# 主循环
while true; do
  main_menu
  case $REPLY in
    1) install_systemd;;
    2) load_config; cloudflare_api "https://api.cloudflare.com/client/v4/zones/$CFZONE_NAME/dns_records" PUT "{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$(get_wan_ip $CFRECORD_TYPE)\",\"ttl\":$CFTTL}";;
    3) view_logs;;
    4) manage_config;;
    5) uninstall_systemd;;
    6) exit 0;;
    *) echo -e "${COLORS[RED]}无效选择${COLORS[NC]}";;
  esac
  read -rsp $'\n按任意键继续...' -n1 key
done
