#!/usr/bin/env python3
"""Drops the quarantine workaround from the Homebrew cask.

A notarised build carries its own stapled ticket, so Gatekeeper accepts it without the
`xattr -dr com.apple.quarantine` postflight the unsigned builds needed. Leaving that in
would keep stripping an attribute that is now doing its job.

Kept as a file rather than inline in the workflow: the replacement text contains lines
indented less than the YAML block that would hold it, which silently ends the block.
"""
import pathlib
import re
import sys

CAVEATS = """
  caveats <<~EOS
    Codex Remote runs in the menu bar and has no Dock icon.
  EOS
"""

def main() -> int:
    cask = pathlib.Path(sys.argv[1])
    text = cask.read_text()

    # The postflight and the comment block above it.
    text = re.sub(r"\n  # This build is ad-hoc signed.*?\n  end\n", "\n", text, flags=re.S)
    # The caveat explaining the trade, which no longer applies.
    text = re.sub(r"\n  caveats <<~EOS.*?EOS\n", CAVEATS, text, flags=re.S)

    cask.write_text(text)
    print(f"cask: removed the quarantine workaround from {cask.name}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
