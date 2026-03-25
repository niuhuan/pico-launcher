#!/usr/bin/env python3

import argparse
import struct
from pathlib import Path


def read_nft2_characters(path: Path) -> set[int]:
    data = path.read_bytes()
    _, _, char_map_ptr, _, _, _, _ = struct.unpack_from("<IIIIBBH", data, 0)
    chars: set[int] = set()
    offset = char_map_ptr
    while True:
        count, start_char = struct.unpack_from("<HH", data, offset)
        if count == 0:
            break
        chars.update(range(start_char, start_char + count))
        offset += 4 + 2 * count
    return chars


def gb2312_characters() -> set[int]:
    chars: set[int] = set()
    for high in range(0xA1, 0xF8):
        for low in range(0xA1, 0xFF):
            try:
                decoded = bytes((high, low)).decode("gb2312")
            except UnicodeDecodeError:
                continue
            if len(decoded) == 1:
                chars.add(ord(decoded))
    return chars


def extra_characters() -> set[int]:
    text = (
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789"
        " .,:;!?+-*/=_()[]{}<>|@#$%^&~`'\"\\"
        "、。·《》「」『』【】（）〔〕〈〉"
        "：；？！￥……—"
    )
    return {ord(ch) for ch in text}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("font", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    chars = read_nft2_characters(args.font)
    chars.update(gb2312_characters())
    chars.update(extra_characters())
    chars.discard(0)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(chr(code) for code in sorted(chars)), encoding="utf-8")


if __name__ == "__main__":
    main()
