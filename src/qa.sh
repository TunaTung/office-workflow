#!/usr/bin/env bash
# qa.sh — 视觉质检（渲染图 → 豆包看图查排版缺陷，零依赖、不重启）
# 用途: AI 代工的最后一环——渲染成 PNG 后，检查文字截断/溢出/豆腐块/元素错位
# 用法:
#   qa.sh <image.png> [question]      → 质检结果到 stdout
#   qa.sh <image.png> --pages n       → 分页图(命名 qa_p0.png qa_p1.png...)批量查
# 依赖: 火山方舟豆包 key(ARK_API_KEY env 或默认) + urllib(标准库)
# 说明: 纯 urllib 调 OpenAI 兼容视觉端点,不需要 Qwen-MM-Plugins/MCP,任意 OpenAI 兼容视觉模型可换
set -u
PY="C:/Python314/python.exe"
# 视觉端点 key 必须来自环境变量（公开仓库不带 key；本机可在 config.env 或 shell 设 ARK_API_KEY）
KEY="${ARK_API_KEY:-}"
URL="${ARK_BASE_URL:-https://ark.cn-beijing.volces.com/api/v3/chat/completions}"
MODEL="${ARK_VISION_MODEL:-doubao-seed-2-0-lite-260428}"
[ -z "$KEY" ] && { echo "缺少 ARK_API_KEY（视觉质检端点 key），export ARK_API_KEY=xxx 后重试" >&2; exit 1; }

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -lt 1 ] && usage
IMG="$1"
[ -f "$IMG" ] || { echo "文件不存在: $IMG" >&2; exit 1; }
shift

# 默认质检问题（排版缺陷为主）
Q="${1:-检查这张文档渲染图排版质量：1)文字截断/溢出/重叠 2)中文豆腐块(方块乱码) 3)元素错位/残留占位符 4)整体可读性。逐项答有/无，最后一句概括。}"
[ "${1:-}" = "--pages" ] && { Q="批量检查文档渲染图排版质量：1)文字截断/溢出/重叠 2)中文豆腐块 3)元素错位/残留占位符。逐项答有/无，每张图一句概括。"; }

"$PY" - "$IMG" "$KEY" "$URL" "$MODEL" "$Q" <<'PYEOF'
import base64, json, sys, urllib.request

img, key, url, model, q = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
b64 = base64.b64encode(open(img, "rb").read()).decode()
payload = {
    "model": model,
    "messages": [{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
        {"type": "text", "text": q},
    ]}],
    "max_tokens": 512, "stream": False,
}
req = urllib.request.Request(url, data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "Authorization": "Bearer " + key}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=90) as r:
        d = json.loads(r.read().decode())
    print(d["choices"][0]["message"]["content"].strip())
except urllib.error.HTTPError as e:
    sys.stderr.write("质检失败: HTTP %s: %s\n" % (e.code, e.read(200).decode("utf-8", "replace")))
    sys.exit(1)
except Exception as e:
    sys.stderr.write("质检失败: %s\n" % str(e)[:200])
    sys.exit(1)
PYEOF
