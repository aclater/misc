#!/usr/bin/env bash
# Keep the copy of bin/roam-guard embedded in fedora_stuff.sh identical to
# bin/roam-guard. fedora_stuff.sh is deliberately one self-contained file (a
# fresh install downloads only it), so the tool is embedded rather than fetched.
#
#   tools/embed-roam-guard.sh           rewrite the embedded copy from bin/roam-guard
#   tools/embed-roam-guard.sh --check   exit 1 if they differ (run before committing)
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "${1:-}" <<'PY'
import sys
from pathlib import Path

target = Path("fedora_stuff.sh")
tool = Path("bin/roam-guard").read_text()
start = "cat > \"$HOME/.local/bin/roam-guard\" <<'ROAM_GUARD_EOF'\n"
end = "ROAM_GUARD_EOF\n"
if end in tool:
    sys.exit("bin/roam-guard contains the heredoc terminator line; pick another marker")

text = target.read_text()
i = text.index(start) + len(start)
j = text.index(end, i)
current = text[i:j]
if sys.argv[1] == "--check":
    if current != tool:
        sys.exit("fedora_stuff.sh's embedded roam-guard differs from bin/roam-guard; "
                 "run tools/embed-roam-guard.sh")
    print("OK: embedded roam-guard matches bin/roam-guard")
else:
    target.write_text(text[:i] + tool + text[j:])
    print("embedded bin/roam-guard into fedora_stuff.sh")
PY
