# 🚀 Cloudflare DDNS 管理脚本  🚀

一个轻量、自动化的 Bash 脚本，用于通过 Cloudflare API 更新您的动态 DNS 记录（IPv4 A 和 IPv6 AAAA）。

## ✨ 主要特性

* **自动更新**: 检测 IP 变化并自动同步到 Cloudflare DNS。
* **双栈支持**: 同时或独立支持 IPv4 和 IPv6 更新。
* **交互式安装**: 友好的命令行向导，一步步完成配置。
* **详细日志**: 记录每次更新状态，方便排错。
* **Telegram 通知**: 可选的 IP 更新状态通知。
* **一键安装/卸载**: 简化部署和移除。

## 🚀 快速开始

### 前提条件

* Linux/Unix 系统 (需 Bash 环境)。
* `sudo` 或 `root` 权限。
* 已安装 `curl`, `grep`, `sed`, `jq`。
    ```bash
    # 例如 Debian/Ubuntu
    sudo apt update && sudo apt install curl grep sed jq -y
    ```

### 一键安装

```bash
wget -N https://raw.githubusercontent.com/Kov1Ki/kov1-ddns/main/cf-ddns.sh && chmod +x cf-ddns.sh && ./cf-ddns.sh
```

## 💡 使用指南

安装后，输入 `sudo d` 或 `sudo cf-ddns.sh` 进入主菜单。

* **手动更新**: `sudo d update`
* **查看日志**: `sudo d log`
* **卸载**: 在主菜单选择 `7. 🗑️ 卸载 DDNS`。

## ⚙️ 配置说明

配置文件位于 `/etc/cf-ddns/config.conf`。建议通过脚本菜单修改。

* **`CFKEY`**: 您的 Cloudflare Global API Key。
* **`CFUSER`**: 您的 Cloudflare 账户邮箱。
* **`CFZONE_NAME`**: 您的主域名 (如 yourdomain.com)。
* **`CFRECORD_NAME_V4`/`CFRECORD_NAME_V6`**: DNS 记录的主机名 (`@` 代表主域名)。
* **`ENABLE_IPV4`/`ENABLE_IPV6`**: 是否启用 (`true`/`false`)。
* **`TG_BOT_TOKEN`/`TG_CHAT_ID`**: Telegram Bot 通知设置 。

## 🔍 故障排除

* **`jq` 命令未找到**: 请确保安装了 `jq`。
* **IP 未更新或报错**: 检查日志文件 `/var/log/cf-ddns.log` 获取详细信息。
