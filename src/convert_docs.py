#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""doc-to-md — 批量把 Office 文档/PDF 转成 Markdown 供 LLM 读取（只读，不改源文件）。

用法:
  python convert_docs.py <文件或目录> [<文件或目录> ...] [-o 输出目录] [-r] [--show] [--ext e1,e2]

行为:
  - 默认扫描给定目录的顶层文件；-r 递归子目录
  - 每份文档转成同名 .md，默认输出到"输入目录/md_out/"
  - 加密/损坏/纯图片 PDF 等失败项记录到 md_out/_failed.txt，不中断
  - --show 转换后把内容打印到 stdout（小批量直接给模型读用）

路由:
  - Office(docx/pptx/xlsx...) → anydoc
  - PDF → pdf-inspector 分类:
      text_based    → pdf-inspector md（位置感知提取）
      scanned/image_based → docling --scan（GPU OCR）
      mixed         → docling 全能力（含文字页表格/公式不弱化）
      pdf-inspector 分类失败 → pymupdf 阈值兜底
      pdf-inspector 空输出（无 ToUnicode 中文字体）→ 降级 docling --scan
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

# 外部 shim 路径：env 覆盖（install 生成的 config.env），默认走 PATH 命令名
PDF_INSPECTOR = os.environ.get("PDF_INSPECTOR_SH", "pdf-inspector.sh")
DOCLING = os.environ.get("DOCLING_SH", "docling.sh")

# anydoc 支持的扩展名（小写，无点）
SUPPORTED = {
    "doc", "docx", "docm",
    "ppt", "pps", "pot", "pptx", "pptm", "ppsx", "ppsm",
    "xls", "xlsx", "xlsm", "xlsb",
    "odt", "ods", "odp",
    "rtf", "epub", "csv", "pdf",
}


def run_shim(cmd: list[str]) -> tuple[int, str]:
    """调 bash shim（Windows 下需 bash 包裹），返回 (退出码, stdout)。stderr 透传。"""
    r = subprocess.run(["bash", "-c", " ".join(f"'{c}'" for c in cmd)],
                       capture_output=True, text=True, encoding="utf-8")
    if r.stderr:
        print(r.stderr, end="", file=sys.stderr)
    return r.returncode, r.stdout


def _pymupdf_classify(f: Path) -> str:
    """pdf-inspector 不可用时的兜底分类：字符<60 或非空页<0.2 → scanned（与 SKILL.md 承诺一致）。"""
    import fitz  # pymupdf（全局已装）
    doc = fitz.open(str(f))
    total_chars = sum(len(p.get_text()) for p in doc)
    non_empty = sum(1 for p in doc if len(p.get_text().strip()) > 0)
    ratio = non_empty / max(len(doc), 1)
    doc.close()
    if total_chars < 60 or ratio < 0.2:
        return "scanned"
    return "text_based"


def convert_file(f: Path) -> str:
    """按类型路由转换单文件，返回 markdown 文本；失败抛异常。"""
    ext = f.suffix.lower().lstrip(".")
    if ext == "pdf":
        # 先分类：文字版 → pdf-inspector；扫描/图片 → docling --scan；混合 → docling 全能力
        code, out = run_shim([PDF_INSPECTOR, "type", str(f)])
        if code != 0:
            print(f"[warn] {f.name}: pdf-inspector 分类失败,用 pymupdf 兜底", file=sys.stderr)
            ptype = _pymupdf_classify(f)
        else:
            ptype = out.strip()
        if ptype in ("scanned", "image_based"):
            code, md = run_shim([DOCLING, "md", "--scan", str(f)])
            if code != 0:
                raise RuntimeError("docling OCR 失败")
            return md
        if ptype == "mixed":
            # 混合：含文字层可能有表格/公式，走全能力不弱化
            code, md = run_shim([DOCLING, "md", str(f)])
            if code != 0:
                raise RuntimeError("docling 全能力转换失败")
            return md
        # text_based 及未知类型 → pdf-inspector md；空输出(如无 ToUnicode 的中文字体)
        # 降级 docling --scan(只需提文本,light 足够,避免 full 模型重编译)
        code, md = run_shim([PDF_INSPECTOR, "md", str(f)])
        if code != 0 or not md.strip():
            if not md.strip():
                print(f"[warn] {f.name}: pdf-inspector 空输出,降级 docling --scan", file=sys.stderr)
            code, md = run_shim([DOCLING, "md", "--scan", str(f)])
            if code != 0:
                raise RuntimeError("docling 提取失败")
        return md
    return _to_markdown_anydoc(f)


def _to_markdown_anydoc(f: Path) -> str:
    """anydoc 延迟导入：未安装时抛错进失败清单，不拖垮整条 PDF 链（降级精神）。"""
    try:
        import anydoc
    except ImportError as e:
        raise RuntimeError("anydoc 未安装（pip install firecrawl-anydoc），Office 文档无法转换") from e
    return anydoc.to_markdown(str(f))


def collect_files(inputs: list[Path], recursive: bool, exts: set[str]) -> list[Path]:
    files = []
    for p in inputs:
        if p.is_file():
            if p.suffix.lower().lstrip(".") in exts:
                files.append(p)
            else:
                print(f"[skip] 不支持的格式: {p}", file=sys.stderr)
        elif p.is_dir():
            it = p.rglob("*") if recursive else p.iterdir()
            for f in it:
                if f.is_file() and f.suffix.lower().lstrip(".") in exts:
                    files.append(f)
        else:
            print(f"[warn] 路径不存在: {p}", file=sys.stderr)
    return files

def main() -> int:
    ap = argparse.ArgumentParser(description="批量文档 → Markdown")
    ap.add_argument("inputs", nargs="+", type=Path, help="文件或目录")
    ap.add_argument("-o", "--out", type=Path, default=None, help="输出目录（默认: 输入目录/md_out）")
    ap.add_argument("-r", "--recursive", action="store_true", help="递归扫描子目录")
    ap.add_argument("--show", action="store_true", help="转换后打印内容到 stdout")
    ap.add_argument("--ext", default=",".join(sorted(SUPPORTED)), help="限定扩展名，逗号分隔")
    args = ap.parse_args()

    exts = {e.strip().lower().lstrip(".") for e in args.ext.split(",") if e.strip()}
    files = collect_files(args.inputs, args.recursive, exts)

    if not files:
        print("[error] 没有可转换的文件", file=sys.stderr)
        return 1

    # 输出目录：-o 指定；否则取第一个输入的目录（文件则取其父目录）
    base_dir = args.inputs[0] if args.inputs[0].is_dir() else args.inputs[0].parent
    out_dir = args.out or (base_dir / "md_out")
    out_dir.mkdir(parents=True, exist_ok=True)

    ok, failed = [], []
    t0 = time.perf_counter()
    used_names = {}  # 同名文件 → 追加数字后缀，避免覆盖
    for i, f in enumerate(files, 1):
        try:
            md = convert_file(f)
            if len(md.strip()) < 50:
                print(f"[warn] {f.name}: 输出过短({len(md.strip())}字符),可能转换不全,请抽检", file=sys.stderr)
            dest = out_dir / (f.stem + ".md")
            n = used_names.get(dest.name, 0) + 1
            if n > 1:
                dest = out_dir / f"{f.stem}_{n}.md"
            used_names[dest.name] = n
            dest.write_text(md, encoding="utf-8")
            ok.append((f, dest, len(md)))
            if args.show:
                print(f"\n===== {f.name} ({len(md)} chars) =====")
                print(md)
        except Exception as e:  # noqa: BLE001
            failed.append((f, type(e).__name__ + ": " + str(e)))

    elapsed = (time.perf_counter() - t0) * 1000
    print(f"\n完成: 成功 {len(ok)} 失败 {len(failed)}  共 {len(files)} 份  {elapsed:.0f} ms")
    if ok:
        print(f"输出目录: {out_dir}")
    if failed:
        fail_file = out_dir / "_failed.txt"
        fail_file.write_text("\n".join(f"{f}\t{err}" for f, err in failed), encoding="utf-8")
        print(f"失败清单: {fail_file}")
        for f, err in failed:
            print(f"  [fail] {f}  →  {err}", file=sys.stderr)
    return 0 if not failed else 2

if __name__ == "__main__":
    raise SystemExit(main())
