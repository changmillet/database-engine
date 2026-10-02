#!/usr/bin/env python3
"""Exercise the committed release migration's real DO block in a rollback-only local fixture."""

import argparse
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/migrations/20261002132339_oauth_release_cli_capabilities.sql"


def migration_block():
    source = MIGRATION.read_text(encoding="utf-8")
    blocks = re.findall(
        r"(?is)\bdo\s+\$oauth_release_cli_capabilities\$.*?\$oauth_release_cli_capabilities\$;",
        source,
    )
    if len(blocks) != 1 or not source.lstrip().startswith("begin;") or not source.rstrip().endswith("commit;"):
        raise ValueError("expected one real release migration DO block with its committed transaction boundary")
    return blocks[0]


def guard_sql():
    # Load the actual committed guard, not a copy of its count predicate.
    block = migration_block().replace("'", "''")
    return f"""
begin;
create extension if not exists pgtap with schema extensions;
set local statement_timeout = '15s';
set local search_path = extensions, public, auth;
select plan(7);
select lives_ok('{block}', 'canonical manifest runs the actual migration');
create temporary table guard_manifest_before as select * from private.api_capability_grants;

delete from private.api_capability_grants
where to_regprocedure(routine_identity) = 'api.assert_lca_release_manager()'::regprocedure;
select throws_ok('{block}', 'P0001', 'OAuth CLI release capability manifest is incomplete or duplicated',
 'actual migration rejects a missing target');
insert into private.api_capability_grants select * from guard_manifest_before
where to_regprocedure(routine_identity) = 'api.assert_lca_release_manager()'::regprocedure;

insert into private.api_capability_grants
select 'api."get_current_lca_release"()', capability_id, allow_anon, allow_authenticated, allow_service_role
from guard_manifest_before where routine_identity = 'api.get_current_lca_release()';
select throws_ok('{block}', 'P0001', 'OAuth CLI release capability manifest is incomplete or duplicated',
 'actual migration rejects a duplicate semantic identity');

delete from private.api_capability_grants
where to_regprocedure(routine_identity) = 'api.assert_lca_release_manager()'::regprocedure;
select is((select count(*) from private.api_capability_grants),
 (select count(*) from guard_manifest_before), 'missing plus duplicate preserves total row count');
select throws_ok('{block}', 'P0001', 'OAuth CLI release capability manifest is incomplete or duplicated',
 'actual migration rejects balanced missing plus duplicate identities');

delete from private.api_capability_grants where routine_identity = 'api."get_current_lca_release"()';
insert into private.api_capability_grants select * from guard_manifest_before
where to_regprocedure(routine_identity) = 'api.assert_lca_release_manager()'::regprocedure;
select lives_ok('{block}', 'restored canonical manifest replays idempotently');
select is((select count(*) from (
 (select * from private.api_capability_grants except select * from guard_manifest_before)
 union all
 (select * from guard_manifest_before except select * from private.api_capability_grants)
) difference), 0::bigint, 'replay preserves every canonical manifest row and role flag');
select * from finish();
rollback;
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-container", required=True, help="explicit task-owned local Database container")
    args = parser.parse_args()
    if not re.fullmatch(r"supabase_db_database-engine(?:-[a-z0-9-]+)?", args.local_container):
        parser.error("requires an explicit local Database container; hosted DSNs are unsupported")
    result = subprocess.run(
        ["docker", "exec", "-i", args.local_container, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"],
        input=guard_sql(), text=True, capture_output=True, timeout=60,
    )
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    # ON_ERROR_STOP/connection close also rolls back if SQL aborts before ROLLBACK.
    passed = re.findall(r"(?m)^ok ([0-9]+)\b", result.stdout)
    if result.returncode or re.search(r"(?m)^not ok\b", result.stdout) or not re.search(r"(?m)^1\.\.7$", result.stdout) or passed != [str(i) for i in range(1, 8)]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
