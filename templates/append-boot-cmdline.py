#!/usr/bin/env python3
"""Append the initial boot arguments to a magiskboot unpack -h header."""
from pathlib import Path
import shlex
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: append-boot-cmdline.py HEADER')
p = Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
indices = [i for i, line in enumerate(lines) if line.startswith('cmdline=')]
if len(indices) != 1:
    raise SystemExit('Expected exactly one cmdline= entry; inspect the header format')
i = indices[0]
line = lines[i]
value = line[len('cmdline='):].rstrip('\r\n')
tokens = shlex.split(value)
for desired in ('rdinit=/init', 'enforcing=0'):
    key = desired.split('=', 1)[0] + '='
    existing = [t for t in tokens if t.startswith(key)]
    if any(t != desired for t in existing):
        raise SystemExit(f'Conflicting boot argument: {existing}; review manually')
    if not existing:
        value += (' ' if value else '') + desired
ending = '\r\n' if line.endswith('\r\n') else '\n'
lines[i] = 'cmdline=' + value + ending
p.write_text(''.join(lines))
