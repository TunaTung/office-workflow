#!/usr/bin/env bash
# docling-serve — docling 常驻服务(GPU 模型只加载一次,批量转换秒级)
# 用法: docling-serve.sh start|stop|status
# 依赖: docling_server.py(fastapi/uvicorn,无 grpcio 包袱);日志 D:/Agent/tool/docling/serve.log
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${DOCLING_PY:-$SCRIPT_DIR/../.venv/Scripts/python.exe}"
SERVER="$SCRIPT_DIR/docling_server.py"
PORT="${DOCLING_SERVE_PORT:-5001}"
LOG="${DOCLING_SERVE_LOG:-$SCRIPT_DIR/../serve.log}"
PIDFILE="${DOCLING_SERVE_PID:-$SCRIPT_DIR/../serve.pid}"
# 预热样本:install 生成的 sample（文字版/扫描件各一，触发 light+full 双模型加载）
WARM_LIGHT="${DOCLING_WARM_LIGHT:-$SCRIPT_DIR/../sample/scan.pdf}"
WARM_FULL="${DOCLING_WARM_FULL:-$SCRIPT_DIR/../sample/report.pdf}"
export HF_HOME="${DOCLING_HF_HOME:-$HOME/.cache/docling-models}"
export TORCHDYNAMO_SUPPRESS_ERRORS=1

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "已在运行 (pid $(cat "$PIDFILE"))"; return 0
  fi
  nohup "$PY" "$SERVER" "$PORT" "$WARM_LIGHT" "$WARM_FULL" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "启动中 (pid $!),预热 light+full 模型 ~4-5 分钟(含 GPU 编译),完成后 md/--scan/mixed 全秒级"
}

stop() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE" && echo "已停止"
  else
    rm -f "$PIDFILE"; echo "未在运行"
  fi
}

status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "运行中 (pid $(cat "$PIDFILE"))"
  else
    echo "未运行"; return 1
  fi
}

case "${1:-}" in
  start) start ;;
  stop)  stop ;;
  status) status ;;
  *) echo "用法: docling-serve.sh start|stop|status"; exit 1 ;;
esac
