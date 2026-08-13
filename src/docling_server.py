#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""docling 常驻服务 — GPU 模型只加载一次,批量转换秒级(替代 docling-serve 的 grpcio 依赖)。

用法: python docling_server.py [port]
  - 启动时预热 light(扫描件) 模型 + GPU 图编译,启动费只付一次
  - POST /convert  {"path": "<文件>", "light": true|false} → {"markdown": "..."}
  - 本机 127.0.0.1 服务,无鉴权(仅本地)

配套: docling-serve.sh start|stop|status; docling.sh 自动优先走本服务,失败回退单进程。
"""
import base64
import logging
import sys
import time

logging.disable(logging.ERROR)
from fastapi import FastAPI, Form

from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions, AcceleratorOptions, AcceleratorDevice

app = FastAPI()

LIGHT_OFF = ("do_table_structure", "do_formula_enrichment", "do_picture_classification",
             "do_chart_extraction", "do_code_enrichment", "do_picture_description")

_conv_light = None
_conv_full = None


def make_conv(light: bool) -> DocumentConverter:
    opts = PdfPipelineOptions()
    if light:
        for a in LIGHT_OFF:
            setattr(opts, a, False)
        opts.ocr_batch_size = 4
    opts.accelerator_options = AcceleratorOptions(device=AcceleratorDevice.CUDA)
    return DocumentConverter(format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=opts)})


def get_conv(light: bool):
    global _conv_light, _conv_full
    if light:
        if _conv_light is None:
            _conv_light = make_conv(True)
        return _conv_light
    if _conv_full is None:
        _conv_full = make_conv(False)
    return _conv_full


@app.post("/convert")
def convert(path_b64: str = Form(...), light: bool = Form(False)):
    # path 经 base64 传输:Windows 下 starlette Form 按 GBK 解码 UTF-8 百分号编码会乱码,
    # base64(纯 ASCII)彻底绕开编码链路
    t0 = time.time()
    try:
        path = base64.b64decode(path_b64).decode("utf-8")
        conv = get_conv(light)
        r = conv.convert(path)
        return {"markdown": r.document.export_to_markdown(), "elapsed": round(time.time() - t0, 2)}
    except Exception as e:
        return {"error": "%s: %s" % (type(e).__name__, str(e))}, 500


if __name__ == "__main__":
    import uvicorn
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5001
    # 预热:light(扫描件)+ full(文字版/混合/公式)两个模型都加载+GPU 编译,
    # 把 ~135s/模型 的启动费付在启动时,之后 md/--scan/mixed 全秒级
    warm_light = sys.argv[2] if len(sys.argv) > 2 else ""
    warm_full = sys.argv[3] if len(sys.argv) > 3 else ""
    if warm_light:
        print("预热 light 模型...", flush=True)
        get_conv(True).convert(warm_light)
    if warm_full:
        print("预热 full 模型...", flush=True)
        get_conv(False).convert(warm_full)
    if warm_light or warm_full:
        print("预热完成,服务就绪", flush=True)
    else:
        print("跳过预热(无 warm 文件),首次请求将付编译费", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
