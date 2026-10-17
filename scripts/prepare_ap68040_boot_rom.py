#!/usr/bin/env python3
"""Make a diagnostic Q800 ROM that takes the existing warm RAM-test exit.

Only for simulator diagnosis. Hardware/release acceptance uses the original ROM.
No ROM contents are included in the repository by this script.
"""
import argparse
import hashlib
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rom", type=Path)
    parser.add_argument("output", type=Path, help="output binary ROM (not hex)")
    args = parser.parse_args()
    source = args.rom.read_bytes()
    expected = "7d9cb8c3bae0e26171adf9f24bedf10bf6371ae3c9bdbcdfd3b94e5350099fb6"
    if hashlib.sha256(source).hexdigest() != expected:
        parser.error("unsupported ROM; expected the unmodified 1 MiB Quadra 800 ROM")
    if args.rom.resolve() == args.output.resolve():
        parser.error("output must differ from the original ROM")
    result = bytearray(source)
    # $40847336: TST.L D6 / BNE $4084734C -> BRA.W $40847346.
    # The ROM's existing warm exit clears D7 and continues at $4084739C.
    assert result[0x47336:0x4733A] == bytes.fromhex("4a866612")
    result[0x47336:0x4733A] = bytes.fromhex("6000000e")
    checksum = sum(int.from_bytes(result[i:i + 2], "big")
                   for i in range(4, len(result), 2)) & 0xFFFFFFFF
    result[:4] = checksum.to_bytes(4, "big")
    args.output.write_bytes(result)
    print(f"Diagnostic ROM: {args.output}; RAM test skipped; checksum {checksum:08x}")


if __name__ == "__main__":
    main()
