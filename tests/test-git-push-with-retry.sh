#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/git-push-with-retry.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

git_id() {
  git -C "$1" config user.name "test-bot"
  git -C "$1" config user.email "test-bot@example.com"
}

setup_origin() {
  local name="$1"
  git init -q --bare -b master "$WORK/$name.git"
  git clone -q -c core.autocrlf=false "$WORK/$name.git" "$WORK/$name-seed" 2>/dev/null
  git_id "$WORK/$name-seed"
  mkdir -p "$WORK/$name-seed/apps/my-app"
  echo '{"image":"my-app:1.0.0"}' > "$WORK/$name-seed/apps/my-app/ppd.json"
  echo '{"image":"my-app:1.0.0"}' > "$WORK/$name-seed/apps/my-app/prod.json"
  git -C "$WORK/$name-seed" add .
  git -C "$WORK/$name-seed" commit -q -m "seed"
  git -C "$WORK/$name-seed" push -q origin master
}

writer() {
  local origin="$1" dir="$2" file="$3" image="$4" msg="$5"
  git clone -q -c core.autocrlf=false "$WORK/$origin.git" "$dir" 2>/dev/null
  git_id "$dir"
  echo "{\"image\":\"$image\"}" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -q -m "$msg"
}

echo "== Case 1: deploy pushes first, rollback push must not fail"
setup_origin c1
writer c1 "$WORK/c1-deploy" apps/my-app/ppd.json my-app:1.1.0 "chore(cd): update deploy metadata"
writer c1 "$WORK/c1-rollback" apps/my-app/prod.json my-app:0.9.0 "rollback(my-app/prod)"
git -C "$WORK/c1-deploy" push -q origin HEAD:master

if git -C "$WORK/c1-rollback" push -q origin HEAD:master 2>/dev/null; then
  fail "plain git push should be rejected when master moved"
else
  pass "plain git push is rejected when master moved (old rollback.yml behavior)"
fi

if (cd "$WORK/c1-rollback" && "$SCRIPT" master) >/dev/null 2>&1; then
  pass "git-push-with-retry.sh pushes after rebase"
else
  fail "git-push-with-retry.sh should push after rebase"
fi

LOG="$(git --git-dir="$WORK/c1.git" log --format=%s master)"
if grep -q "rollback(my-app/prod)" <<< "$LOG" && grep -q "update deploy metadata" <<< "$LOG"; then
  pass "master keeps both the deploy and the rollback commits"
else
  fail "master should keep both commits"
fi

echo "== Case 2: deploy and rollback push at the same time"
setup_origin c2
writer c2 "$WORK/c2-deploy" apps/my-app/ppd.json my-app:1.1.0 "chore(cd): update deploy metadata"
writer c2 "$WORK/c2-rollback" apps/my-app/prod.json my-app:0.9.0 "rollback(my-app/prod)"
(cd "$WORK/c2-deploy" && "$SCRIPT" master) >/dev/null 2>&1 &
PID_DEPLOY=$!
(cd "$WORK/c2-rollback" && "$SCRIPT" master) >/dev/null 2>&1 &
PID_ROLLBACK=$!
wait "$PID_DEPLOY"; RC_DEPLOY=$?
wait "$PID_ROLLBACK"; RC_ROLLBACK=$?

if [[ "$RC_DEPLOY" -eq 0 && "$RC_ROLLBACK" -eq 0 ]]; then
  pass "both concurrent pushes succeed"
else
  fail "concurrent pushes: deploy=$RC_DEPLOY rollback=$RC_ROLLBACK"
fi

COUNT="$(git --git-dir="$WORK/c2.git" rev-list --count master)"
if [[ "$COUNT" -eq 3 ]]; then
  pass "master has seed + deploy + rollback commits"
else
  fail "master should have 3 commits, has $COUNT"
fi

echo "== Case 3: real conflict on the same JSON fails cleanly"
setup_origin c3
writer c3 "$WORK/c3-a" apps/my-app/prod.json my-app:1.1.0 "chore(cd): update deploy metadata"
writer c3 "$WORK/c3-b" apps/my-app/prod.json my-app:0.9.0 "rollback(my-app/prod)"
git -C "$WORK/c3-a" push -q origin HEAD:master
BEFORE="$(git --git-dir="$WORK/c3.git" rev-parse master)"

if (cd "$WORK/c3-b" && "$SCRIPT" master) >/dev/null 2>&1; then
  fail "conflicting push should fail"
else
  pass "conflicting push exits with error"
fi

if [[ ! -d "$WORK/c3-b/.git/rebase-merge" && ! -d "$WORK/c3-b/.git/rebase-apply" ]]; then
  pass "rebase is aborted, no rebase left in progress"
else
  fail "rebase should be aborted"
fi

if [[ "$(git --git-dir="$WORK/c3.git" rev-parse master)" == "$BEFORE" ]]; then
  pass "master is not changed by the failed push"
else
  fail "master should not change"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
