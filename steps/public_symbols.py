"""Print the functions that PDFium's public headers declare with FPDF_EXPORT."""

import pathlib
import re
import sys

names = set()
for header in sorted(pathlib.Path(sys.argv[1]).glob("*.h")):
    text = re.sub(r"//[^\n]*|/\*.*?\*/", "", header.read_text(encoding="utf-8"), flags=re.S)
    found = re.findall(r"\bFPDF_EXPORT\b[^;{}()]*?\bFPDF_CALLCONV\s+(\w+)\s*\(", text)
    # A declaration the pattern misses would be hidden from static consumers.
    exports = len(re.findall(r"^(?!\s*#).*\bFPDF_EXPORT\b", text, flags=re.M))
    if len(found) != exports:
        sys.exit(f"{header}: parsed {len(found)} of {exports} FPDF_EXPORT declarations")
    names.update(found)
if not names:
    sys.exit(f"no FPDF_EXPORT declarations in {sys.argv[1]}")
print("\n".join(sorted(names)))
