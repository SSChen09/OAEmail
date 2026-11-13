# -*- coding: utf-8 -*-
"""生成文件共享测试样本：t3.bin（3MB，正常上传）、big.bin（21MB，应被拒绝）。"""
import os


def main():
    with open("t3.bin", "wb") as f:
        f.write(os.urandom(3 * 1024 * 1024))
    with open("big.bin", "wb") as f:
        f.write(os.urandom(21 * 1024 * 1024))
    print("ok: t3.bin (3MB), big.bin (21MB)")
    return 0


if __name__ == "__main__":
    main()
