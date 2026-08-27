#!/bin/zsh

set -u

BASE_DIR="/Users/sunkanwei/Myapp/音频"
APP_DIR="$BASE_DIR/runtime/optimized/mlx"
PYTHON="$APP_DIR/.venv/bin/python"
SERVER="$APP_DIR/scripts/sa3_gradio.py"
HELPER="$BASE_DIR/后台服务.zsh"
RUN_DIR="$BASE_DIR/.run"
PID_FILE="$RUN_DIR/音乐工作室.pid"
LOG_FILE="$RUN_DIR/音乐工作室.log"
URL="http://127.0.0.1:7860"
SERVICE_LABEL="com.sunkanwei.music-studio"
SERVICE_TARGET="gui/$(/usr/bin/id -u)/$SERVICE_LABEL"

finish() {
    local exit_code="$1"
    local message="$2"
    echo "$message"
    exit "$exit_code"
}

is_our_process() {
    local pid="$1"
    [[ "$pid" == <-> ]] || return 1
    /bin/kill -0 "$pid" 2>/dev/null || return 1
    /bin/ps -p "$pid" -o command= 2>/dev/null | /usr/bin/grep -Fq "$SERVER"
}

find_running_pid() {
    local pid=""
    if [[ -f "$PID_FILE" ]]; then
        pid="$(/bin/cat "$PID_FILE" 2>/dev/null)"
        if is_our_process "$pid"; then
            echo "$pid"
            return 0
        fi
        /bin/rm -f "$PID_FILE"
    fi

    pid="$(/usr/sbin/lsof -nP -tiTCP:7860 -sTCP:LISTEN 2>/dev/null | /usr/bin/head -n 1)"
    if [[ -n "$pid" ]] && is_our_process "$pid"; then
        echo "$pid"
        return 0
    fi
    return 1
}

if /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
    service_pid="$(/bin/cat "$PID_FILE" 2>/dev/null || true)"
    /bin/launchctl remove "$SERVICE_LABEL" >/dev/null 2>&1 || \
        finish 1 "关闭失败：无法停止音乐工作室。"
    for _ in {1..50}; do
        if ! /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1 \
            && ! is_our_process "$service_pid" \
            && ! /usr/sbin/lsof -nP -iTCP:7860 -sTCP:LISTEN >/dev/null 2>&1; then
            /bin/rm -f "$PID_FILE"
            finish 0 "已关闭音乐工作室。"
        fi
        /bin/sleep 0.2
    done
    finish 1 "关闭超时：音乐工作室仍在退出，请稍后再试。"
fi

if pid="$(find_running_pid)"; then
    /bin/kill -TERM "$pid" 2>/dev/null || finish 1 "关闭失败：无法停止音乐工作室。"
    for _ in {1..25}; do
        if ! /bin/kill -0 "$pid" 2>/dev/null; then
            /bin/rm -f "$PID_FILE"
            finish 0 "已关闭音乐工作室。"
        fi
        /bin/sleep 0.2
    done
    if is_our_process "$pid"; then
        /bin/kill -KILL "$pid" 2>/dev/null || true
    fi
    /bin/rm -f "$PID_FILE"
    finish 0 "已关闭音乐工作室。"
fi

[[ -x "$PYTHON" && -f "$SERVER" && -x "$HELPER" ]] || \
    finish 1 "启动失败：音乐工作室环境不完整。"
if /usr/sbin/lsof -nP -iTCP:7860 -sTCP:LISTEN >/dev/null 2>&1; then
    finish 1 "启动失败：本机端口已被其他程序占用。"
fi

/bin/mkdir -p "$RUN_DIR" "$BASE_DIR/.cache/huggingface" \
    "$BASE_DIR/.cache/gradio" "$BASE_DIR/.cache/uv" \
    "$BASE_DIR/.python" "$BASE_DIR/.tmp" "$BASE_DIR/outputs"

/bin/launchctl submit -l "$SERVICE_LABEL" -o "$LOG_FILE" -e "$LOG_FILE" -- \
    "$HELPER" || finish 1 "启动失败：无法注册音乐工作室服务。"

for _ in {1..180}; do
    if /usr/bin/curl -fsS "$URL" >/dev/null 2>&1; then
        /usr/bin/open "$URL"
        finish 0 "音乐工作室已启动，并已在浏览器中打开。"
    fi
    if ! /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
        /bin/rm -f "$PID_FILE"
        echo "运行记录：$LOG_FILE"
        finish 1 "启动失败：音乐工作室进程已退出。"
    fi
    /bin/sleep 0.25
done

echo "运行记录：$LOG_FILE"
finish 1 "启动超时：程序仍在准备，请稍后再试。"
