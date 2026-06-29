#!/usr/bin/env python3
"""P1 确定性 golden 烟测(见 docs/message-hub.md §12)。

不用手跑 JetBrains:本脚本写一份**固定**的合成转录 + 重放一组**固定**的 hook 事件到
`~/.vibenotch/sock`(完全模拟真实 hook),让 VibeNotch 把这条合成终端会话产成 ui 帧。
同一输入 → 可复现的帧 → 迁移前录 baseline、迁移后录 hub,直接 golden-diff.py 比对。

用法:
    # 前置:VibeNotch 在跑、且 RelayAgent 已上线(手机/网页连着中转),否则不发帧。
    scripts/golden-smoke.py ~/.vibenotch/golden/baseline.jsonl     # 迁移前
    scripts/golden-smoke.py ~/.vibenotch/golden/hub.jsonl          # 迁移后
    scripts/golden-diff.py  ~/.vibenotch/golden/baseline.jsonl ~/.vibenotch/golden/hub.jsonl
"""
import json, os, socket, sys, time, pathlib

HOME = os.path.expanduser("~")
SOCK = f"{HOME}/.vibenotch/sock"
GOLDEN_DIR = f"{HOME}/.vibenotch/golden"
RECORD = f"{GOLDEN_DIR}/RECORD"
FRAMES = f"{GOLDEN_DIR}/frames.jsonl"

# 固定身份:路径必须含 /.claude/(ClaudeAgent.handlesTranscript 才认),用专属测试目录隔离。
SID = "golden-smoke-fixed-0001"
PROJ_DIR = f"{HOME}/.claude/projects/golden-smoke"
TX = f"{PROJ_DIR}/{SID}.jsonl"
CWD = "/tmp/golden-smoke-project"
PPID = os.getpid()   # 真实存活的 pid:既能做终端探测,又不会被判成 console 子进程

# 固定合成转录:turn0(历史回填)+ turn1(当前轮:分析文本 + 读文件 + 跑命令 + 收尾文字)。
# 当前轮边界 = 最后一条用户消息(turn1 的);turn0 成为「当前轮之前」的历史。
TRANSCRIPT = [
    # ── turn 0(历史)──
    {"type": "user", "message": {"role": "user",
        "content": [{"type": "text", "text": "第一轮:先看下 README"}]}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "好,我看下 README。"},
        {"type": "tool_use", "name": "Read", "input": {"file_path": f"{CWD}/README.md"}}]}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "README 看完了,继续。"}]}},
    # ── turn 1(当前轮)──
    {"type": "user", "message": {"role": "user",
        "content": [{"type": "text", "text": "帮我看下 main.py 并列出目录"}]}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "好的,我先读一下 `main.py`,再看看目录结构。"},
        {"type": "tool_use", "name": "Read", "input": {"file_path": f"{CWD}/main.py"}}]}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "Bash", "input": {"command": "ls -la"}}]}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "读完了,目录里有 3 个文件,主入口是 `main.py`。"}]}},
]

# 固定事件序列(模拟真实 hook 的生命周期):提交 → 工具×2 → 结束。
def ev(name, **kw):
    e = {"hook_event_name": name, "session_id": SID, "cwd": CWD,
         "transcript_path": TX, "_ppid": PPID}
    e.update(kw); return e

EVENTS = [
    ev("UserPromptSubmit", prompt="帮我看下 main.py 并列出目录"),
    ev("PreToolUse",  tool_name="Read", tool_input={"file_path": f"{CWD}/main.py"}),
    ev("PostToolUse", tool_name="Read", tool_input={"file_path": f"{CWD}/main.py"}),
    ev("PreToolUse",  tool_name="Bash", tool_input={"command": "ls -la"}),
    ev("PostToolUse", tool_name="Bash", tool_input={"command": "ls -la"}),
    ev("Stop"),
]


def send(obj):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(SOCK)
    s.sendall((json.dumps(obj) + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    try:
        while s.recv(4096):   # 读完响应 = 确保服务端已处理这条,保证顺序
            pass
    except Exception:
        pass
    s.close()


def main():
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(2)
    out = os.path.expanduser(sys.argv[1])
    if not os.path.exists(SOCK):
        print(f"✗ 找不到 {SOCK} —— VibeNotch 没在跑?"); sys.exit(1)

    pathlib.Path(PROJ_DIR).mkdir(parents=True, exist_ok=True)
    pathlib.Path(GOLDEN_DIR).mkdir(parents=True, exist_ok=True)
    with open(TX, "w") as f:
        for line in TRANSCRIPT:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")

    # 干净起录:清掉旧 frames,打开 RECORD
    if os.path.exists(FRAMES):
        os.remove(FRAMES)
    pathlib.Path(RECORD).touch()
    time.sleep(0.3)

    print(f"重放 {len(EVENTS)} 个 hook 事件 (sid={SID}) …")
    for e in EVENTS:
        send(e)
        time.sleep(0.45)        # 给 store/RelayAgent 合并 + 推送留时间
    time.sleep(1.8)             # Stop 后 reply-poll/sync 收尾

    # 停录 + 收割本会话的帧
    if os.path.exists(RECORD):
        os.remove(RECORD)
    time.sleep(0.3)

    kept = 0
    with open(out, "w") as fo:
        if os.path.exists(FRAMES):
            for line in open(FRAMES):
                line = line.strip()
                if not line:
                    continue
                try:
                    if json.loads(line).get("sid") == SID:
                        fo.write(line + "\n"); kept += 1
                except Exception:
                    pass

    # 清理合成会话(发 SessionEnd 让它从 store 消失,不在控制台残留)
    try:
        send(ev("SessionEnd"))
    except Exception:
        pass

    print(f"录到 {kept} 帧 → {out}")
    if kept == 0:
        print("⚠ 0 帧。检查:RelayAgent 是否已上线(手机/网页连着中转)?没连就不发帧。")
        sys.exit(1)
    print("✓ 完成。迁移后再跑一次产 hub.jsonl,然后 golden-diff.py 比对。")


main()
