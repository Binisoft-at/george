#!/usr/bin/env bash
# Publishes CI results to a branch that can be read with plain git – no Actions API needed:
#   git fetch origin ci-output && git show origin/ci-output:ci/status.txt
# Replaces only <subdir> on the branch (other folders stay), as a single commit without history so
# screenshots never bloat the repository. Pushes made with GITHUB_TOKEN don't trigger workflows.
#   usage: publish-output.sh <source dir> <message> [branch=ci-output] [subdir=.]
#   env:   GH_TOKEN, GITHUB_REPOSITORY
# Synced from the Binisoft handbook.
set -euo pipefail
src=$(cd "$1" && pwd)
message=$2
branch=${3:-ci-output}
subdir=${4:-.}
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}"
remote="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

for attempt in 1 2 3 4 5; do
  work=$(mktemp -d)
  git -C "$work" init -q
  git -C "$work" config user.name "Binisoft CI"
  git -C "$work" config user.email "ci@users.noreply.github.com"
  old=""
  if [ "$subdir" != "." ] && git -C "$work" fetch -q --depth 1 "$remote" "refs/heads/$branch" 2>/dev/null; then
    old=$(git -C "$work" rev-parse FETCH_HEAD)
    git -C "$work" checkout -q FETCH_HEAD -- . 2>/dev/null || true
  elif [ "$subdir" = "." ]; then
    old=$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | cut -f1 || true)
  fi
  if [ "$subdir" != "." ]; then rm -rf "${work:?}/${subdir:?}"; fi
  mkdir -p "$work/$subdir"
  cp -R "$src"/. "$work/$subdir"/
  date -u "+%Y-%m-%d %H:%M:%S UTC" > "$work/$subdir/published-at.txt"
  git -C "$work" add -A
  tree=$(git -C "$work" write-tree)
  commit=$(git -C "$work" commit-tree "$tree" -m "$message")
  if git -C "$work" push -q --force-with-lease="refs/heads/$branch:$old" "$remote" "$commit:refs/heads/$branch"; then
    rm -rf "$work"
    echo "Published to $branch ($subdir): $message"
    exit 0
  fi
  rm -rf "$work"
  echo "Push to $branch raced with another run (attempt $attempt) – retrying"
  sleep $((attempt * 3))
done
echo "::warning::Could not publish to $branch"
exit 1
