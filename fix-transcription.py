"""
Fix markdown transcription sections: add blank lines between timestamp segments.
Usage: python3 fix-transcription.py <file.md>

Problem: Whisper outputs lines like:
  [00:00:00] text\n
  [00:00:08] text\n
Markdown treats single newlines as spaces → one giant paragraph.

Fix: Add blank line before each [timestamp] line so each becomes its own <p>.
"""
import re
import sys

def fix_transcription(content):
    # Find ## Transcrição section
    match = re.search(r'(##\s+Transcrição\s*\n)', content, re.IGNORECASE)
    if not match:
        print("No '## Transcrição' section found — nothing to fix.")
        return content, False

    start = match.end()
    # Find next ## section or end of file
    next_sec = re.search(r'\n## ', content[start:])
    end = start + next_sec.start() if next_sec else len(content)

    trans_block = content[start:end]

    # Add blank line before each [timestamp] line (unless already blank)
    # Replaces: \n[  →  \n\n[
    fixed_block = re.sub(r'\n(\[)', r'\n\n\1', trans_block)

    if fixed_block == trans_block:
        print("Already formatted — no changes needed.")
        return content, False

    return content[:start] + fixed_block + content[end:], True

if len(sys.argv) < 2:
    print("Usage: python3 fix-transcription.py <file.md>")
    sys.exit(1)

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    content = f.read()

fixed, changed = fix_transcription(content)

if changed:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(fixed)
    print(f"Fixed: {path}")
else:
    print(f"No changes: {path}")
