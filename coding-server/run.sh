#!/usr/bin/env bash
# coding-server 启动 / 模拟脚本。用 IDEA 自带 Maven（无需本地安装 mvn）。
set -euo pipefail
cd "$(dirname "$0")"

MVN="${MVN:-/Applications/IntelliJ IDEA.app/Contents/plugins/maven/lib/maven3/bin/mvn}"
[ -x "$MVN" ] || MVN="./mvnw"   # 兜底:用项目自带的 Maven Wrapper

case "${1:-server}" in
  server)
    # 启动中转服务：Spring MVC(8080) + Netty 中转 WS(8090)
    exec "$MVN" -q -DskipTests spring-boot:run
    ;;
  sim)
    # 端到端模拟：Agent 推协议帧 → 服务器 → 手机端 Client 接收（需先另开一个终端跑 ./run.sh server）
    "$MVN" -q compile
    exec java -cp target/classes com.aicodingremote.sim.Simulator "${2:-demo}" "${3:-ws://127.0.0.1:8090/ws}"
    ;;
  *)
    echo "用法: ./run.sh [server|sim] [account] [wsUrl]"
    exit 1
    ;;
esac
