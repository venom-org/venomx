#!/usr/bin/env python3
"""docs/site/reference/commands.md is `venomx docs` with a frontmatter.

The docs site publishes docs/site/ as the venomx docs. The command reference is
generated from the verb schema, so it goes stale when a verb changes. Run with
`--write` (`zig build site-docs`) to regenerate it; without, fail if it differs.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

EXE = str(Path(sys.argv[1]).resolve())
WRITE = '--write' in sys.argv[2:]
TARGET = Path(__file__).resolve().parent.parent / 'docs' / 'site' / 'reference' / 'commands.md'
HEADER = """---
title: Command reference
description: Every venomx verb, its flags, result and errors, generated from the verb schema.
order: 9
generated: by `zig build site-docs` from `venomx docs`; do not edit
---
"""

# `docs` reads no daemon or config, but keep the caller's environment out of it.
with tempfile.TemporaryDirectory(prefix='vx-docs-') as home:
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': home, 'XDG_RUNTIME_DIR': home}
    body = subprocess.run([EXE, 'docs'], check=True, capture_output=True, text=True, env=env, timeout=30).stdout

want = HEADER + body
if WRITE:
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(want)
    print(f'wrote {TARGET}')
    sys.exit(0)

have = TARGET.read_text() if TARGET.exists() else ''
if have != want:
    print(f'{TARGET} is stale: run `zig build site-docs` and commit it', file=sys.stderr)
    sys.exit(1)
