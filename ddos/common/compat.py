#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
 compat.py —— 靶机 / 攻击机共用的兼容层（仅 agent.py、attacker.py 内联使用）
==============================================================================
 部署形态：目标机器上只有 agent.py 与 attacker.py 两个单文件，故本文件**不单独上传**，
          其全部内容已内联在两个脚本各自的 "# 兼容层" 区块中（保持单文件要求）。
 本文件作为开发期参考实现，并与两份内联实现保持逐字一致。

 兼容目标：Python 2.7 ~ 3.x（含 CentOS7 自带 2.7.5 的 python，以及 python36）
 关键点：
   1. print(..., flush=True) 仅在 Python 3.3+ 可用 —— Python 2 里 print 是语句，
      `print(x, flush=True)` 会被解析成“打印元组 (x, True)”，在部分环境中报 SyntaxError。
   2. os.geteuid() 仅 Unix 存在，已在调用处用 hasattr 判断。
   3. dict/list/str 的迭代写法、f-string、bytes 字面量等一律不使用或已规避。

 用法（内联到主脚本）：
     try:
         input = raw_input
     except NameError:
         pass

     def say(msg):
         sys.stdout.write(str(msg) + "\\n")
         sys.stdout.flush()
==============================================================================
"""

import sys

# Python2: input() 也会 eval 用户输入，统一用 raw_input 语义
try:
    input = raw_input  # noqa: F821  (仅 Python2 存在)
except NameError:
    pass


def say(msg):
    """跨版本安全输出：先写 stdout 再立即 flush（替代 print(..., flush=True)）"""
    sys.stdout.write(str(msg) + "\n")
    sys.stdout.flush()


def say_err(msg):
    sys.stderr.write(str(msg) + "\n")
    sys.stderr.flush()


def ensure_utf8_stdio():
    """Python3 下强制 stdio 使用 UTF-8，避免中文在 POSIX locale 下 UnicodeEncodeError"""
    if sys.version_info[0] < 3:
        return
    for name in ("stdout", "stderr"):
        stream = getattr(sys, name)
        rec = getattr(stream, "reconfigure", None)   # Python2 的 stream 无此方法
        if rec is None:
            continue
        try:
            rec(encoding="utf-8")
        except Exception:
            pass
