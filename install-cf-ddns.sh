#!/bin/bash
# 下载地址：https://raw.githubusercontent.com/Kov1Ki/kov1-ddns/main/install-cf-ddns.sh

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[0;31m错误: 此脚本需要 root 权限运行\033[0m"
  exit 1
fi

# 定义变量
SCRIPT_URL="https://raw.githubusercontent.com/你的用户名/你的仓库/main/cf-ddns.sh"
INSTALL_PATH="/usr/local/bin/cf-ddns"
LINK_PATH="/usr/local/bin/ddns"

echo -e "\033[1;33m正在下载 Cloudflare DDNS 脚本...\033[0m"
curl -sSL "$SCRIPT_URL" -o "$INSTALL_PATH" || {
  echo -e "\033[0;31m下载失败! 请检查网络连接\033[0m"
  exit 1
}

echo -e "\033[0;34m设置执行权限...\033[0m"
chmod 755 "$INSTALL_PATH"

echo -e "\033[0;34m创建快捷命令: ddns\033[0m"
ln -sf "$INSTALL_PATH" "$LINK_PATH"

echo -e "\033[1;32m安装成功!\033[0m"
echo -e "现在可以运行以下命令进行配置:"
echo -e "  sudo ddns install"
