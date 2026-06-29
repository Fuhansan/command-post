#!/usr/bin/env python3
"""P1 golden 帧比对(见 docs/message-hub.md §12)。

用法: golden-diff.py <baseline.jsonl> <hub.jsonl>

按 (帧类型 t, 消息 id) 取每条的**最终态**比对;忽略传输字段(seq / time,
它们每次运行都变,不代表渲染差异)。默认只比 hook 帧(sid 不以 'c:' 开头)。
退出码 0 = 完全一致;1 = 有差异(并打印明细)。
"""
import json, sys, collections

VOLATILE = {"time", "seq"}   # 传输/时间字段:跨运行必变,比对时剥掉


def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if k not in VOLATILE}
    if isinstance(o, list):
        return [strip(x) for x in o]
    return o


def load(path, hook_only=True):
    final = collections.OrderedDict()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            fr = json.loads(line)
            if hook_only and str(fr.get("sid", "")).startswith("c:"):
                continue
            final[(fr.get("t"), fr.get("id"))] = strip(fr)   # 同 id 后到的覆盖 → 最终态
    return final


def dump(o):
    return json.dumps(o, sort_keys=True, ensure_ascii=False)


def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    ak, bk = set(a), set(b)
    only_a, only_b = ak - bk, bk - ak
    diffs = [k for k in (ak & bk) if dump(a[k]) != dump(b[k])]
    print(f"baseline 唯一消息: {len(a)}   hub: {len(b)}")
    print(f"仅基线有: {len(only_a)}");  [print("  -", k) for k in sorted(map(str, only_a))]
    print(f"仅 hub 有: {len(only_b)}");  [print("  +", k) for k in sorted(map(str, only_b))]
    print(f"内容不一致: {len(diffs)}")
    for k in sorted(diffs, key=str):
        print("  ~", k)
        print("    base:", dump(a[k]))
        print("    hub :", dump(b[k]))
    if not only_a and not only_b and not diffs:
        print("✓ 完全一致(已忽略 seq/time)"); sys.exit(0)
    sys.exit(1)


main()
