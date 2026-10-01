#!/usr/bin/env bash
set -uo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sub"
printf '#!/usr/bin/env bash\necho ok\nexit 0\n' > "$T/sub/a-pass.test.sh"
printf '#!/usr/bin/env bash\necho boom\nexit 1\n' > "$T/sub/b-fail.test.sh"
out=$(bash /root/qbx-harness/tests/run.sh --dir "$T/sub" 2>&1); rc=$?
echo "$out" | grep -q '^ok   a-pass.test.sh' || { echo "missing ok line"; exit 1; }
echo "$out" | grep -q '^FAIL b-fail.test.sh' || { echo "missing FAIL line"; exit 1; }
[ "$rc" -eq 1 ] || { echo "runner rc=$rc want 1"; exit 1; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/sub/b-fail.test.sh"
out=$(bash /root/qbx-harness/tests/run.sh --dir "$T/sub" 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'failed: 0' || { echo "green run failed"; exit 1; }
exit 0
