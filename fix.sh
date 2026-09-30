#!/bin/bash
# 一键修好服务器 - 直接在你的 mac 终端运行这条命令：
# bash /Users/liushujun/Documents/heartbeat/fix.sh

IP="47.82.159.182"
PASS="bYwku0-dantyx-qozgiq"
SRC="/Users/liushujun/Documents/heartbeat/server.js"

# 上传修复后的 server.js
scp -o StrictHostKeyChecking=no "$SRC" root@$IP:/root/dylan-heartbeat/server.js

# 进服务器重启
ssh -o StrictHostKeyChecking=no root@$IP "cd /root/dylan-heartbeat && pm2 delete gateway && pm2 start server.js --name gateway && pm2 save"
