#!/usr/bin/env bash
# Database #834: a bounded, real canonical-base R4 -> R5 migration regression.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "${1:-}" == "--help" ]]; then
  echo "CI-only: requires the matching GitHub-hosted workspace, local Docker and SCOPE_CLOSURE_UPGRADE_ALLOW_RESET=isolated."
  exit 0
fi
if [[ "${SCOPE_CLOSURE_UPGRADE_ALLOW_RESET:-}" != "isolated" ]]; then
  echo "Refusing local reset without SCOPE_CLOSURE_UPGRADE_ALLOW_RESET=isolated." >&2
  exit 2
fi
if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" || "${GITHUB_WORKSPACE:-}" != "$repo_root" ]]; then
  echo "Refusing reset outside the matching GitHub-hosted ephemeral workspace." >&2
  exit 2
fi
if [[ -n "${DOCKER_HOST:-}" || -n "${DOCKER_CONTEXT:-}" ]]; then
  echo "Refusing overridden Docker target." >&2
  exit 2
fi
docker_endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
if [[ "$docker_endpoint" != unix://* ]]; then
  echo "Refusing non-local Docker context." >&2
  exit 2
fi

fixture="$(mktemp "$repo_root/supabase/tests/upgrade/scanner-r5-upgrade-XXXXXX.sql")"
trap 'rm -f "$fixture"' EXIT

python3 - "$fixture" <<'PY'
import hashlib
from pathlib import Path
import subprocess
import sys

base = "03939b8880f983d494406f0e10b213081b9f900a"
base_version = "20261011151720"
migration = Path("supabase/migrations/20261012082933_advance_scope_closure_lcia_metadata_scanner_revision.sql")
source = Path("supabase/tests/20260722_scope_closure_release_binding_e2e.sql")
paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", base, "--", "supabase/migrations"], text=True).splitlines()
paths = {path for path in paths if path.endswith(".sql")}
if max(Path(path).name.split("_", 1)[0] for path in paths) != base_version:
    raise SystemExit("Canonical base migration version mismatch")
# Reset uses checkout files: ensure its entire prefix is the recorded canonical
# base, while allowing future migrations after the bounded proof finishes.
prefix = {str(path) for path in Path("supabase/migrations").glob("*.sql") if path.name.split("_", 1)[0] <= base_version}
changed = subprocess.check_output(["git", "diff", "--name-only", base, "--", "supabase/migrations"], text=True).splitlines()
if prefix != paths or any(path in paths for path in changed):
    raise SystemExit("Checkout migrations no longer reproduce the exact canonical base")
# This historical proof must not inherit current-only package receipts or
# relative includes. CI's full-history checkout supplies this exact canonical
# object; missing history fails before reset and never falls back to HEAD.
fixture_revision = "3711a8e8e671decc5e77cd37341b9f5d83b622b6"
fixture_blob = "3028724ba603a9d4b60e6c6abc64f7354a9faf59"
fixture_sha256 = "bb2d1bbb7840647f07fe1fcd01cbf26f2e06b26ad570d918de916cf6223510f8"
try:
    source_bytes = subprocess.check_output(
        ["git", "show", f"{fixture_revision}:{source}"], stderr=subprocess.PIPE
    )
except subprocess.CalledProcessError as error:
    raise SystemExit(
        f"Missing pinned scanner fixture {fixture_revision}:{source}; "
        "the CI checkout must include canonical history (fetch-depth: 0)"
    ) from error
blob_header = f"blob {len(source_bytes)}\0".encode()
if (hashlib.sha1(blob_header + source_bytes).hexdigest() != fixture_blob
        or hashlib.sha256(source_bytes).hexdigest() != fixture_sha256):
    raise SystemExit("Pinned scanner fixture blob/hash mismatch")
body = source_bytes.decode("utf-8")
start = "-- SCANNER_R5_MIGRATION_BEGIN"
end = "-- SCANNER_R5_MIGRATION_END"
if body.count(start) != 1 or body.count(end) != 1:
    raise SystemExit("Expected one explicit scanner migration injection boundary")
before, rest = body.split(start)
_, after = rest.split(end)
sql = migration.read_text()
checks = """
select is((select expected_validator_scanner_fingerprint from private.lcia_scope_closure_config where singleton),
  'scope-closure-validator-scanner.v1+cutoff-readiness-r5', 'actual migration activates R5');
select is((select to_jsonb(c) - 'expected_validator_scanner_fingerprint' - 'updated_at'
           from private.lcia_scope_closure_config c where singleton),
          (select body from scanner_upgrade_config_before),
          'actual migration preserves every other configuration field');
"""
rendered = (
    "\\set scope_closure_initial_scanner 'scope-closure-validator-scanner.v1+cutoff-readiness-r4'\n"
    + before
    + "create temporary table scanner_upgrade_config_before as select to_jsonb(c) - 'expected_validator_scanner_fingerprint' - 'updated_at' as body from private.lcia_scope_closure_config c where singleton;\n"
    + sql + checks + sql + checks + after
)
Path(sys.argv[1]).write_text(rendered)
print(f"Canonical base: {base}; fixture: {fixture_revision}:{source} blob {fixture_blob}; migration SHA256: {hashlib.sha256(sql.encode()).hexdigest()}; two actual SQL applications in rollback fixture")
PY

supabase db reset --local --version 20261011151720 --no-seed
# pg_prove, used by the existing Supabase runner, fails on not-ok TAP results as
# well as SQL errors. The shared fixture verifies populated R4 rows are intact.
supabase test db "$fixture"
# The bounded proof above ran only the R5 migration against canonical R4.
# Restore the normal checkout state for subsequent CI suites; later migrations
# cannot affect what the preceding upgrade assertions proved.
supabase migration up --local
