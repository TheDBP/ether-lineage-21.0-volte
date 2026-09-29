#!/usr/bin/env bash
# check-sigpipe.sh — fail if any shell script that runs under `set -o pipefail` pipes into
# `grep -q` or `head`. Both exit before EOF; the producer then takes SIGPIPE (141); pipefail turns
# a SUCCESS into a failure — silently, and only once the input is big enough that grep/head win the
# race. Recurs across scripts here. Use capture-then-
# count instead:  n=$(producer | grep -c NEEDLE || true).
#
# Run: tools/check-sigpipe.sh   (also wired as .githooks/pre-commit). Add a trailing `# sigpipe-ok`
# to a line to suppress a genuine false positive.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

bad=0
while IFS= read -r f; do
  grep -qE 'pipefail' "$f" 2>/dev/null || continue    # only scripts that actually use pipefail
  # Blank out comments first (pure-comment lines, and trailing ' #...') so a warning ABOUT the trap
  # in a comment isn't flagged as the trap. sed keeps the line count, so grep -n stays accurate.
  # Then: a single pipe ( '|' not '||' ) into grep -...q..., or into head. `[^|]\|` avoids `||`.
  hits="$(sed -E 's/^[[:space:]]*#.*//; s/[[:space:]]#.*//' "$f" \
          | grep -nE '[^|]\| *grep +-[A-Za-z]*q[A-Za-z]*|[^|]\| *head( |$)' 2>/dev/null \
          | grep -v 'sigpipe-ok' || true)"
  [ -n "$hits" ] || continue
  echo "!! $f — unsafe pipe under pipefail (grep -q / head SIGPIPEs the producer):"
  echo "$hits" | sed 's/^/     /'
  bad=1
done < <(git ls-files '*.sh')

if [ "$bad" -eq 0 ]; then
  echo "check-sigpipe: clean"
else
  echo "check-sigpipe: FAIL — rewrite as  n=\$(producer | grep -c NEEDLE || true)  (or mark # sigpipe-ok)"
fi
exit "$bad"
