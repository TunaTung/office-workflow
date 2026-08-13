#!/usr/bin/env bash
# install.sh — 一键重建 office-workflow 环境（检测→venv→依赖→config→sample）
#
# 用法:
#   bash install.sh                       # CPU 模式（PyPI 装 torch，能跑但扫描件慢）
#   DOCLING_GPU=1 bash install.sh        # GPU 模式（NVIDIA 4060+；torch cu126 走阿里云镜像，~2.4GB）
#   DOCLING_LOCAL_WHEELS=/path/to/wheels bash install.sh  # 用本地 cu126 wheel 目录（离线/复用缓存）
#
# 幂等：已存在的步骤自动跳过，可重复运行。
# 产物：
#   .venv/            独立 Python 环境（不污染系统）
#   config.env        本机实际路径（install 自动生成，供 src 各脚本读取）
#   sample/scan.pdf + sample/report.pdf  （serve 预热 + 验证用）
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$(pwd)"

echo "═══ office-workflow 安装 ═══"

# 1) 检测 Python 3.10-3.14（docling 2.119 支持 <4.0,>=3.10，3.14 实测可用）
PY_BIN=""
# 候选列表：显式 PYTHON > python3/python/py（PATH）> Windows 常见落点（C:\Python3xx\）
cands=()
[ -n "${PYTHON:-}" ] && cands+=("$PYTHON")
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 && cands+=("$(command -v "$c")")
done
for p in /c/Python*/python.exe; do
  [ -e "$p" ] && cands+=("$p")
done
for cand in "${cands[@]}"; do
  case "$cand" in
    *WindowsApps*) continue ;;  # Windows Store stub：运行即退、无输出，跳过
  esac
  VER="$("$cand" -c 'import sys;print(".".join(map(str,sys.version_info[:2])))' 2>/dev/null)"
  case "$VER" in
    3.10|3.11|3.12|3.13|3.14) PY_BIN="$cand"; break ;;
  esac
done
if [ -z "$PY_BIN" ]; then
  echo "[FAIL] 未找到可用 Python 3.10-3.14，请设置 PYTHON=/path/to/python3.12"; exit 1
fi
echo "[1/5] Python $VER ✓ ($PY_BIN)"

# 2) 建 venv
VENV="$REPO/.venv"
if [ ! -f "$VENV/Scripts/python.exe" ] && [ ! -f "$VENV/bin/python" ]; then
  echo "[2/5] 创建虚拟环境 $VENV ..."
  "$PY_BIN" -m venv "$VENV" || { echo "[FAIL] venv 创建失败"; exit 1; }
else
  echo "[2/5] venv 已存在，跳过"
fi
PY="$VENV/Scripts/python.exe"; [ -f "$PY" ] || PY="$VENV/bin/python"

# 3) 依赖：torch（CPU/GPU）+ docling 全家 + 工具
echo "[3/5] 安装依赖（首次会下载，耐心等待）..."
if [ -n "${DOCLING_LOCAL_WHEELS:-}" ] && [ -d "$DOCLING_LOCAL_WHEELS" ]; then
  echo "      使用本地 wheel 目录: $DOCLING_LOCAL_WHEELS"
  "$PY" -m pip install --force-reinstall --no-deps \
    "$DOCLING_LOCAL_WHEELS"/torch-2.13.0+cu126-*.whl \
    "$DOCLING_LOCAL_WHEELS"/torchvision-0.28.0+cu126-*.whl || exit 1
elif [ "${DOCLING_GPU:-0}" = "1" ]; then
  echo "      GPU 模式：torch cu126（~2.4GB）..."
  echo "      建议：用下载器（FluxDown/aria2 多线程，实测 100KB/s→8MB/s）先下好两个 wheel，"
  echo "            再 DOCLING_LOCAL_WHEELS=/path/to/wheels 重跑本脚本。"
  echo "      URL（阿里云镜像）:"
  echo "        https://mirrors.aliyun.com/pytorch-wheels/cu126/torch-2.13.0%2Bcu126-cp314-cp314-win_amd64.whl"
  echo "        https://mirrors.aliyun.com/pytorch-wheels/cu126/torchvision-0.28.0%2Bcu126-cp314-cp314-win_amd64.whl"
  if command -v aria2c >/dev/null 2>&1; then
    echo "      检测到 aria2c，直接多线程下载..."
    mkdir -p "$REPO/.wheels" && cd "$REPO/.wheels"
    aria2c -x16 -s16 --console-log-level=warn \
      "https://mirrors.aliyun.com/pytorch-wheels/cu126/torch-2.13.0%2Bcu126-cp314-cp314-win_amd64.whl" \
      "https://mirrors.aliyun.com/pytorch-wheels/cu126/torchvision-0.28.0%2Bcu126-cp314-cp314-win_amd64.whl" || exit 1
    "$PY" -m pip install --force-reinstall --no-deps ./*.whl || exit 1
    cd "$REPO"
  else
    echo "      [FAIL] 未装 aria2c，请先用下载器下好 wheel 再重跑（勿用 curl 单线程下 2.4GB）"
    exit 1
  fi
else
  echo "      CPU 模式：PyPI 装 torch（能用但扫描件慢，建议 GPU）"
fi
echo "      安装 docling + 其余依赖..."
PIP_INDEX_FLAG=""
[ -n "${PIP_INDEX:-}" ] && PIP_INDEX_FLAG="-i $PIP_INDEX"
"$PY" -m pip install $PIP_INDEX_FLAG -r requirements.txt || { echo "[FAIL] 依赖安装失败"; exit 1; }

# 4) 生成 config.env（本机实际路径）
echo "[4/5] 生成 config.env ..."
# 探测 pdf-inspector（分层路由的第一环，缺它 PDF 分类走 pymupdf 兜底）
PDF_INSPECTOR_SH="${PDF_INSPECTOR_SH:-}"
if [ -z "$PDF_INSPECTOR_SH" ]; then
  for p in /d/Agent/tool/pdf-inspector/pdf-inspector.sh /opt/pdf-inspector/pdf-inspector.sh \
           "$HOME/.local/bin/pdf-inspector.sh"; do
    [ -f "$p" ] && { PDF_INSPECTOR_SH="$p"; break; }
  done
fi
if [ -z "$PDF_INSPECTOR_SH" ] && command -v pdf-inspector.sh >/dev/null 2>&1; then
  PDF_INSPECTOR_SH="$(command -v pdf-inspector.sh)"
fi
if [ -z "$PDF_INSPECTOR_SH" ]; then
  echo "  [warn] 未找到 pdf-inspector.sh：PDF 分类将走 pymupdf 兜底（功能可用但慢）"
  echo "         安装后设置 PDF_INSPECTOR_SH=/path/to/pdf-inspector.sh 重跑本脚本"
fi
cat > "$REPO/config.env" <<EOF
# office-workflow 本机配置（install.sh 自动生成）
# 带 export：source 后即进程环境变量，convert_docs.py(os.environ) 与 shim 都能读到
export DOCLING_PY=$PY
export DOCLING_HF_HOME=$HOME/.cache/docling-models
export DOCLING_SERVE_PORT=5001
export PDF_INSPECTOR_SH=${PDF_INSPECTOR_SH:-}
export DOCLING_SH=$REPO/src/docling.sh
EOF
echo "      已写入 config.env（后续运行前 source 它）"

# 5) 生成 sample（serve 预热 + 验证）
echo "[5/5] 生成 sample PDF ..."
echo "      [提示] 首次启动 serve 会从 HuggingFace 下模型（~500MB）。国内网络需设镜像："
echo "             export HF_ENDPOINT=https://hf-mirror.com   再 bash src/docling-serve.sh start"
echo "             或复用已有缓存：DOCLING_HF_HOME=/已有模型目录"
"$PY" - "$REPO/sample" <<'PYEOF' || { echo "[FAIL] sample 生成失败（缺 reportlab）"; exit 1; }
import sys, os
from pathlib import Path
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, Spacer
from reportlab.lib import colors
from reportlab.lib.units import cm
from reportlab.pdfgen import canvas
from PIL import Image, ImageDraw, ImageFont

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)

def font(size, bold=False):
    for p in ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if os.path.exists(p):
            try: return ImageFont.truetype(p, size)
            except Exception: pass
    return ImageFont.load_default()

# report.pdf：文字版（含表格/公式/中文），触发 full 模型
try:
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.cidfonts import UnicodeCIDFont
    pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
    CJK = 'STSong-Light'
except Exception:
    CJK = 'Helvetica'
doc = SimpleDocTemplate(str(out / "report.pdf"), pagesize=A4)
h1 = ParagraphStyle('h1', fontName=CJK, fontSize=16, spaceAfter=10)
h2 = ParagraphStyle('h2', fontName=CJK, fontSize=12, spaceBefore=10, spaceAfter=6)
b  = ParagraphStyle('b', fontName=CJK, fontSize=10, leading=14)
data = [["参数", "数值", "单位"], ["温度", "25.3", "°C"], ["湿度", "62", "%"], ["压强", "101.3", "kPa"]]
t = Table(data, colWidths=[5*cm, 4*cm, 3*cm])
t.setStyle(TableStyle([('GRID',(0,0),(-1,-1),0.5,colors.grey), ('FONTNAME',(0,0),(-1,-1),CJK)]))
doc.build([Paragraph("实验数据汇总", h1), Paragraph("一、原理：E = hf - W，斜率 k = h/e。", h2),
           Paragraph("二、数据：", h2), t, Spacer(1,8),
           Paragraph("拟合斜率 4.14×10^-15 V·s，R² = 0.9996。", b)])

# scan.pdf：纯图片页（无文本层），触发 light 模型
img = Image.new("RGB", (600, 848), (255,255,255))
d = ImageDraw.Draw(img)
f = font(26)
d.text((40,60), "扫描件示例", font=f, fill=(20,20,20))
d.text((40,140), "数据: 电阻 100Ω 电流 0.12A", font=f, fill=(20,20,20))
img.save(str(out / "scan_page.png"))
c = canvas.Canvas(str(out / "scan.pdf"), pagesize=A4)
c.drawImage(str(out / "scan_page.png"), 40, 60, width=515, height=728)
c.save()
os.remove(str(out / "scan_page.png"))
print("sample: report.pdf + scan.pdf 已生成")
PYEOF

echo
echo "═══ 安装完成 ═══"
echo "下一步（AI 照做即可）："
echo "  source config.env"
echo "  bash src/docling-serve.sh start   # 预热 light+full 模型 4-5 分钟（仅首次）"
echo "  bash src/docling.sh md sample/scan.pdf     # 验证扫描件 OCR"
echo "  python src/convert_docs.py sample/ -o sample/md_out   # 验证批量路由"
