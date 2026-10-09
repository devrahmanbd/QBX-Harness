#!/usr/bin/env bash
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sub"
printf '#!/usr/bin/env bash\necho ok\nexit 0\n' > "$T/sub/a-pass.test.sh"
printf '#!/usr/bin/env bash\necho boom\nexit 1\n' > "$T/sub/b-fail.test.sh"
out=$(bash "$H/tests/run.sh" --dir "$T/sub" 2>&1); rc=$?
echo "$out" | grep -q '^ok   a-pass.test.sh' || { echo "missing ok line"; exit 1; }
echo "$out" | grep -q '^FAIL b-fail.test.sh' || { echo "missing FAIL line"; exit 1; }
[ "$rc" -eq 1 ] || { echo "runner rc=$rc want 1"; exit 1; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/sub/b-fail.test.sh"
out=$(bash "$H/tests/run.sh" --dir "$T/sub" 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'failed: 0' || { echo "green run failed"; exit 1; }
# empty dir: no phantom failure from unmatched *.test.sh glob
mkdir -p "$T/empty"
out=$(bash "$H/tests/run.sh" --dir "$T/empty" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "empty-dir rc=$rc want 0"; exit 1; }
echo "$out" | grep -q 'tests: 0, failed: 0' || { echo "empty-dir bad summary: $out"; exit 1; }
# default dir: runner without --dir runs tests from the script's own directory
mkdir -p "$T/def"
cp "$H/tests/run.sh" "$T/def/run.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/def/c-pass.test.sh"
out=$(cd "$T/def" && bash run.sh 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "default-dir rc=$rc want 0"; exit 1; }
echo "$out" | grep -q '^ok   c-pass.test.sh' || { echo "default-dir missing ok line"; exit 1; }
echo "$out" | grep -q 'failed: 0' || { echo "default-dir missing failed: 0"; exit 1; }
exit 0
