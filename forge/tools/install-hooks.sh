#!/usr/bin/env bash
# Install this repo's git hooks into .git/hooks.
#
# Hooks cannot be version-controlled directly, so a fresh clone has none and every guard that
# claims to run "on commit" silently does not. Run this once per clone.
#
#   tools/install-hooks.sh
#
# Bypass a hook for one commit with  git commit --no-verify.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOKS"

cat > "$HOOKS/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Installed by tools/install-hooks.sh. Do not edit here; edit the installer.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"

staged="$(git diff --cached --name-only --diff-filter=ACM || true)"

case "$staged" in
  *.sh|*.sh*)
    if [ -x "$ROOT/tools/check-sigpipe.sh" ]; then
      "$ROOT/tools/check-sigpipe.sh" || {
        echo "!! pre-commit: check-sigpipe failed. Fix it, or commit with --no-verify." >&2
        exit 1
      }
    fi
    ;;
esac
HOOK

chmod +x "$HOOKS/pre-commit"
echo "   installed $HOOKS/pre-commit"
echo "   guards: check-sigpipe.sh (when a shell file is staged)"
