#!/usr/bin/env bash
# test/test-d2-doc.sh
#
# Validates that INFORME_DE_ARQUITECTURA.md documents the D2 change:
#   - presigned-URL upload flow in §3.4 (ConfirmUpload + CORS)
#   - D2 ADR entry in §10 (problem, options, chosen, consequences)
#   - Mermaid sequence diagram for D2
#
# Exits 0 when the doc is up to date; non-zero otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFORME="$REPO_ROOT/INFORME_DE_ARQUITECTURA.md"

[ -f "$INFORME" ] || { echo "FAIL: $INFORME not found"; exit 1; }

fail() { echo "FAIL: $1"; exit 1; }

# §3.4 rewrite: must mention the new flow concepts
grep -q 'ConfirmUpload' "$INFORME" || fail "§3.4 does not describe ConfirmUpload"
grep -qi 'CORS' "$INFORME" || fail "§3.4 does not mention CORS for MinIO"
grep -q 'presign' "$INFORME" || fail "§3.4 does not mention presigned URLs"

# §10 ADR entry: a line that starts with D2 (heading-style) and mentions MinIO
grep -qiE '^#+ .*D2.*MinIO' "$INFORME" || fail "§10 D2 ADR entry missing"
grep -qE 'Consecuencias|Consequences' "$INFORME" || fail "D2 entry missing 'Consecuencias' section"

# Mermaid sequence diagram specifically for D2 (in addition to the §2 topology one)
MERMAID_COUNT="$(grep -c '^```mermaid' "$INFORME" || true)"
[ "$MERMAID_COUNT" -ge 2 ] || fail "expected at least 2 Mermaid blocks (topology + D2 sequence); found $MERMAID_COUNT"

echo "PASS: D2 presigned-URL flow documented in INFORME_DE_ARQUITECTURA.md"
