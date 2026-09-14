#!/bin/bash
# MWB Mac 端命令行版启动脚本（调试用）
#
# 用法:
#   MWB_KEY='Windows 上显示的安全密钥' ./start_mwb.sh <Windows的IP>
#
# 说明：安全密钥请不要写死在文件里，用环境变量传入。
cd "$(dirname "$0")"

HOST="${1:-${MWB_HOST:-192.168.1.100}}"
PORT="${MWB_PORT:-15101}"
KEY="${MWB_KEY:?请先设置环境变量 MWB_KEY —— 它等于 Windows 上 PowerToys「无界鼠标」里显示的安全密钥}"

echo "启动 MWB Mac 客户端 → $HOST:$PORT"
echo "把鼠标撞到屏幕边缘即可接管 Windows；反向推回切回 Mac；Control+Option+Esc 强制收回"
echo "Ctrl+C 退出"
echo "----------------------------------------"
exec ./bin/mwbmac "$HOST" "$PORT" "$KEY"
