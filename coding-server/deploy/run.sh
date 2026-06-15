#!/usr/bin/env bash
# coding-server 简易启停脚本(没配 systemd 时用;生产建议用 systemd,见 README）。
# 用法: ./run.sh {start|stop|restart|status|log}
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
JAR="$DIR/coding-server.jar"
PIDFILE="$DIR/server.pid"
LOG="$DIR/server.log"

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

start() {
  if is_running; then echo "已在运行 (pid=$(cat "$PIDFILE"))"; exit 0; fi
  command -v java >/dev/null 2>&1 || { echo "✗ 没装 java,请先装 Java 17+(见 README)"; exit 1; }
  # -Xmx256m 够用;数据/图片落在工作目录的 data/ 下
  nohup java -Xmx256m -jar "$JAR" > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "✓ 已启动 pid=$(cat "$PIDFILE")"
  echo "  日志: $LOG  (用 ./run.sh log 跟踪)"
  echo "  8080=HTTP(登录/图片) 8090=WS(中转),确认云防火墙已放开这两个端口"
}

stop() {
  if ! is_running; then echo "未运行"; rm -f "$PIDFILE"; exit 0; fi
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  for _ in $(seq 1 10); do is_running || break; sleep 1; done
  is_running && kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "✓ 已停止"
}

case "${1:-start}" in
  start)   start;;
  stop)    stop;;
  restart) stop; sleep 2; start;;
  status)  if is_running; then echo "运行中 pid=$(cat "$PIDFILE")"; else echo "未运行"; fi;;
  log)     tail -f "$LOG";;
  *) echo "用法: $0 {start|stop|restart|status|log}";;
esac
