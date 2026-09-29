#!/usr/bin/env bash
# dev-shell.sh — authoring container. Host needs only Docker.
# Runs the build image with the repos root mounted at /repos: clone/edit/format-patch/git-am/commit
# in-container. Only `git push` uses host auth (GH_TOKEN, else `gh auth token`).
#   dev-shell.sh [cmd...]   # no args = interactive shell
# Env: REPOS (default: parent of this repo), IMAGE (default aosp-los22:24.04), GH_TOKEN.
set -euo pipefail

FORGE="$(cd "$(dirname "$0")/.." && pwd)"
REPOS="${REPOS:-$(cd "$FORGE/.." && pwd)}"
IMAGE="${IMAGE:-aosp-los22:24.04}"
TOKEN="${GH_TOKEN:-}"; [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1 && TOKEN="$(gh auth token 2>/dev/null || true)"

# Runs inside the container before the user command. The heredoc is quoted, so $GH_TOKEN stays LITERAL
# in the stored credential helper and is expanded by git (from the container env) only at push time.
read -r -d '' INIT <<'EOS' || true
git config --global --add safe.directory '*'
git config --global credential.helper '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
EOS

COMMON=(--rm -v "$REPOS":/repos -w /repos
  # Commit identity inside the container. Override per user or in CI; the default is a noreply
  # address so nothing personal lands in a patch From: line.
  -e GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-rom-forge}"
  -e GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-rom-forge@users.noreply.github.com}"
  -e GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-rom-forge}"
  -e GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-rom-forge@users.noreply.github.com}"
  -e GH_TOKEN="$TOKEN")

if [ "$#" -eq 0 ]; then
  exec docker run -it "${COMMON[@]}" "$IMAGE" bash -lc "$INIT"$'\n''exec bash'
else
  exec docker run     "${COMMON[@]}" "$IMAGE" bash -lc "$INIT"$'\n'"$*"
fi
