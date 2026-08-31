#!/bin/zsh

set -e

UPSCALER_DIR="/Users/sunkanwei/Myapp/放大"
if [[ ! -f "$UPSCALER_DIR/env.zsh" || ! -x "$UPSCALER_DIR/.venv/bin/python" ]]; then
    echo "无法切换：图片放大工具的位置或运行环境不完整。"
    exit 1
fi
cd "$UPSCALER_DIR"
source ./env.zsh

# Keep the menu action short-lived; the service owns a separate process group.
exec .venv/bin/python - <<'PY'
import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

root = Path.cwd().resolve()
state = root / ".state"
url = "http://127.0.0.1:8769"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def status():
    try:
        with opener.open(url + "/api/status", timeout=0.5) as response:
            data = json.load(response)
    except (OSError, urllib.error.URLError):
        return None
    except (ValueError, TypeError):
        raise RuntimeError("端口上的程序返回了无效状态；没有停止任何进程。") from None
    if (not isinstance(data, dict) or data.get("service") != "local-image-upscaler"
            or data.get("project_directory") != str(root)):
        raise RuntimeError("端口被其他服务占用；没有停止任何进程。")
    return data


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def stop(data):
    pid = data.get("server_pid")
    if not isinstance(pid, int) or pid <= 1 or pid == os.getpid():
        raise RuntimeError("无法确认服务进程，未执行关闭。")
    # Verify OS process location in addition to the HTTP service identity.
    cwd = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                         capture_output=True, text=True, timeout=3)
    if f"n{root}" not in cwd.stdout.splitlines():
        raise RuntimeError("服务进程位置不匹配，未执行关闭。")
    worker = data.get("compute_pid")
    os.kill(pid, signal.SIGTERM)
    for _ in range(150):
        if not alive(pid) and (not worker or not alive(worker)):
            print("已关闭放大服务，计算进程已退出。未保存的内存结果不再保留。")
            return
        time.sleep(0.1)
    raise RuntimeError("关闭尚未完成，请稍后再试；没有强制结束其他进程。")


def start():
    with socket.socket() as probe:
        probe.settimeout(0.5)
        if probe.connect_ex(("127.0.0.1", 8769)) == 0:
            raise RuntimeError("端口已占用或服务尚未就绪，请稍后再试；没有启动重复服务。")
    # A starting/stopping service may hold the lock before/after listening.
    with (state / "server.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("服务正在启动或退出，请稍后再试。") from None
    logs = state / "logs"
    logs.mkdir(exist_ok=True)
    with (logs / "meno-service.log").open("w") as log:
        child = subprocess.Popen(["/bin/zsh", str(root / "服务.command")], cwd=root,
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 start_new_session=True, close_fds=True)
    try:
        for _ in range(50):
            if status():
                try:
                    subprocess.run(["/usr/bin/open", url], check=True, timeout=5,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except (OSError, subprocess.SubprocessError):
                    print(f"放大服务已开启，但未能自动打开浏览器。请手动打开：{url}")
                else:
                    print("已开启放大服务，并已请求打开网页。再次点击可关闭服务。")
                return
            if child.poll() is not None:
                raise RuntimeError("启动失败，服务进程已退出；请查看放大项目内的服务日志。")
            time.sleep(0.2)
        raise RuntimeError("启动超时，已请求撤销本次启动；请查看放大项目内的服务日志。")
    finally:
        if sys.exc_info()[0] is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=7)
            except subprocess.TimeoutExpired:
                print("服务仍在退出，请稍后检查；未强制结束进程。")


try:
    state.mkdir(exist_ok=True)
    with (state / "meno-toggle.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("正在切换服务，请勿重复点击。") from None
        current = status()
        stop(current) if current else start()
except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
    print(f"放大服务切换失败：{exc}")
    sys.exit(1)
PY
