#!/usr/bin/env bash
# docling — PDF/Office/图片 → 结构化 Markdown（2026-08-13 接入，v2.119.0，MIT，IBM）
# 定位: doc-to-md 第四档——含公式/复杂版面/大表格的 PDF 文献（anydoc/pdf-inspector 的补位）
#      表格强(TableFormer)、公式→LaTeX(中等)、版面/阅读顺序重建;扫描件 OCR 落点(rapidocr)
# 用法:
#   docling.sh md <file.pdf|docx|pptx|xlsx|png>     → markdown 到 stdout（全能力:版面+表格+公式）
#   docling.sh md --scan <file> [-o out.md]         → 轻量(仅版面+OCR,实测约2倍):纯扫描件用
#   docling.sh md <file> -o out.md                  → 写文件
# 注意:
#   - 首次运行下载模型(几百MB)到 D:/Agent/tool/docling/models(HF_HOME 已指,不写 C 盘)
#   - 公式→LaTeX 弱于 MinerU;重度公式论文仍建议 MinerU(需另装 Py3.12)
#   - 扫描件默认走 --scan(关表格/公式/图表模型,启动+每页都提速);含表格的扫描件用全能力
#   - 失败输出错误到 stderr 且退出码=1(不静默吞错)
set -u
# 可配置项（install 生成的 config.env 覆盖；默认相对仓库布局: src/../.venv, ~/.cache/docling-models）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${DOCLING_PY:-$SCRIPT_DIR/../.venv/Scripts/python.exe}"
export HF_HOME="${DOCLING_HF_HOME:-$HOME/.cache/docling-models}"
DOCLING_SERVE_PORT="${DOCLING_SERVE_PORT:-5001}"
# 无 VS Build Tools(cl.exe) 环境:torch inductor 编译失败 → 回退 eager(模型小,CPU 无感)
export TORCHDYNAMO_SUPPRESS_ERRORS=1

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -lt 2 ] && usage
MODE="$1"
LIGHT=0
SRC="$2"
if [ "$MODE" = "md" ] && [ "$2" = "--scan" ]; then LIGHT=1; SRC="${3:-}"; fi
[ -z "${SRC:-}" ] && usage
WIN=$(cygpath -w "$SRC" 2>/dev/null || echo "$SRC")
OUTWIN=""
[ $# -ge 4 ] && [ "${3:-}" = "-o" ] && OUTWIN=$(cygpath -w "$4" 2>/dev/null || echo "$4")
[ $# -ge 5 ] && [ "$3" = "--scan" ] && [ "${4:-}" = "-o" ] && OUTWIN=$(cygpath -w "$5" 2>/dev/null || echo "$5")

case "$MODE" in
  md)
    # serve 优先(GPU 模型常驻,秒级);服务未起/失败 → 回退单进程(付 ~135s 启动费)
    # 路径 base64 传输:绕开 Windows Form 编码乱码坑
    B64=$(printf '%s' "$WIN" | base64 -w0 2>/dev/null || printf '%s' "$WIN" | base64)
    RESP=$(curl -s --noproxy '*' --max-time 900 -X POST "http://127.0.0.1:$DOCLING_SERVE_PORT/convert" \
      --data-urlencode "path_b64=$B64" --data-urlencode "light=$LIGHT" 2>/dev/null) || RESP=""
    if [ -n "$RESP" ]; then
      if OUT=$("$PY" -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    sys.stdout.write(d.get('markdown') or '')
except Exception:
    sys.exit(1)
" "$RESP" 2>/dev/null); then
        if [ -n "$OUTWIN" ]; then
          printf '%s' "$OUT" > "$OUTWIN" && echo "saved -> $OUTWIN"
        else
          printf '%s' "$OUT"
        fi
        exit 0
      fi
    fi
    # 回退:单进程转换
    "$PY" - "$WIN" "$OUTWIN" "$LIGHT" <<'PYEOF'
import sys, logging
# 压噪音:logging.disable 是全局开关,不受 rapidocr 内部 basicConfig 重置影响;
# ERROR+ 保留(真错误走下方 try/except 显式输出,torch graph-break 警告上千行全压)
logging.disable(logging.ERROR)
import docling
from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions

src, out, light = sys.argv[1], sys.argv[2] or None, sys.argv[3] == "1"
opts = PdfPipelineOptions()
if light:
    # 扫描件只需要版面+OCR;表格/公式/图表/图片分类对纯扫描件是浪费(受控实测约2倍提速)
    opts.do_table_structure = False
    opts.do_formula_enrichment = False
    opts.do_picture_classification = False
    opts.do_chart_extraction = False
    opts.do_code_enrichment = False
    opts.do_picture_description = False
    opts.ocr_batch_size = 4
try:
    conv = DocumentConverter(format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=opts)})
    r = conv.convert(src)
    md = r.document.export_to_markdown()
except Exception as e:
    sys.stderr.write("docling 转换失败: %s: %s\n" % (type(e).__name__, e))
    sys.exit(1)
if out:
    with open(out, "w", encoding="utf-8") as f:
        f.write(md)
    print("saved -> %s" % out)
else:
    print(md)
PYEOF
    ;;
  *)
    echo "用法: docling.sh md [--scan] <file> [-o out.md]" >&2
    exit 1 ;;
esac
