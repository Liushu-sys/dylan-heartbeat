#!/bin/bash

IP="47.82.159.182"
PASS="bYwku0-dantyx-qozgiq"
DIR="/root/dylan-heartbeat"

echo "===== 1. 安装依赖 ====="
brew install sshpass 2>/dev/null || true

echo "===== 2. 上传文件 ====="
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no /Users/liushujun/Documents/heartbeat/server.js /Users/liushujun/Documents/heartbeat/wake_up.js /Users/liushujun/Documents/heartbeat/ntfy_priority.js /Users/liushujun/Documents/heartbeat/.env root@$IP:/root/dylan-heartbeat/

echo "===== 3. 安装环境 & 启动 ====="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@$IP bash << 'CMDS'
  export DEBIAN_FRONTEND=noninteractive
  
  # 检查并安装 Node.js
  if ! command -v node &>/dev/null; then
    apt update -y
    apt install -y curl gnupg
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
  fi
  
  # 安装依赖
  cd /root/dylan-heartbeat
  [ ! -f package.json ] && npm init -y
  npm install fastify dotenv fs-extra @fastify/formbody
  npm install -g pm2
  
  # 启动
  pm2 delete gateway 2>/dev/null || true
  pm2 delete wake-up 2>/dev/null || true
  pm2 start server.js --name gateway
  pm2 start wake_up.js --name wake-up
  pm2 save
  pm2 startup 2>/dev/null || true
  pm2 status
CMDS

echo ""
echo "===== 部署完成！ ====="
echo "服务器地址: http://$IP:3000"
echo "请去阿里云安全组开放端口 3000"
echo "然后在 Kelivo 网关供应商填: http://$IP:3000"
