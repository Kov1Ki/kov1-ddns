#!/bin/bash
# Cloudflare DDNS 安装脚本
# 使用方法: bash <(curl -sL https://raw.githubusercontent.com/Kov1Ki/kov1-ddns/main/install.sh)

REPO_URL="https://raw.githubusercontent.com/Kov1Ki/kov1-ddns/main"

echo -e "\033[1;33m正在下载 Cloudflare DDNS 脚本...\033[0m"
curl -sL -o /tmp/cf-ddns.sh "${REPO_URL}/cf-ddns.sh"
chmod +x /tmp/cf-ddns.sh

echo -e "\033[1;32m开始安装...\033[0m"
sudo /tmp/cf-ddns.sh install
