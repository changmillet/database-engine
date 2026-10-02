#!/usr/bin/env python3
"""Rollback-only tests of the actual release-manifest repair and frozen predecessors."""
import argparse
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase/migrations"
NAMES = [
    "assert_lca_release_manager", "cmd_lca_release_prepare", "cmd_lca_release_approve",
    "cmd_lca_release_publish", "cmd_lca_release_readback_verify", "cmd_lca_release_unpublish",
    "get_current_lca_release", "get_lca_release_run", "get_lca_release_artifact_download",
    "get_lcia_result_calculation_bundle", "get_current_lca_release_process",
]


def actual_block(filename, tag):
    source = (MIGRATIONS / filename).read_text()
    blocks = re.findall(rf"(?is)\bdo\s+\${tag}\$.*?\${tag}\$;", source)
    if len(blocks) != 1 or not source.lstrip().startswith("begin;") or not source.rstrip().endswith("commit;"):
        raise ValueError("expected the actual migration block and committed transaction boundary")
    return "'" + blocks[0].replace("'", "''") + "'"


def test_sql():
    block = actual_block("20261002154951_release_manifest_drift.sql", "release_manifest_drift")
    previous = actual_block("20261002132339_oauth_release_cli_capabilities.sql", "oauth_release_cli_capabilities")
    old = (MIGRATIONS / "20260831120000_oauth_actor_command_capabilities.sql").read_text()
    assert old.startswith("begin;") and old.rstrip().endswith("commit;")
    old_body = old[len("begin;"):old.rfind("commit;")]
    names = ",".join("'" + name + "'" for name in NAMES)
    reset = """update private.api_capability_grants m
    set capability_id=b.capability_id,allow_anon=b.allow_anon,allow_authenticated=b.allow_authenticated,allow_service_role=b.allow_service_role
    from canonical_before b where to_regprocedure(m.routine_identity)::oid=b.oid;"""
    return f"""
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
set local statement_timeout='30s';
select plan(23);
insert into private.oauth_client_registry(client_id,client_kind,enabled)
values('database770-manifest-guard-test','mcp_client',true);
insert into private.oauth_client_capability_grants(client_id,capability_id)
values('database770-manifest-guard-test','DB-CORE-READ-01');
create temporary table client_before as select to_jsonb(r) row from private.oauth_client_registry r;
create temporary table grants_before as select to_jsonb(r) row from private.oauth_client_capability_grants r;
create temporary table canonical_before as
select p.oid,p.proacl,m.*,m.ctid::text row_tid from private.api_capability_grants m
join pg_proc p on p.oid=to_regprocedure(m.routine_identity)
join pg_namespace n on n.oid=p.pronamespace where n.nspname='api' and p.proname in({names});
do $baseline$ begin
 if (select count(*) from canonical_before)<>11 or exists(
 select 1 from canonical_before b join pg_proc p on p.oid=b.oid where
 b.capability_id is distinct from case when p.proname='get_current_lca_release_process' then 'EDGE-REL-01' else 'CLI-RPC-01' end
 or b.allow_anon is distinct from has_function_privilege('anon',p.oid,'execute')
 or not b.allow_authenticated
 or b.allow_service_role is distinct from has_function_privilege('service_role',p.oid,'execute')
 ) then raise exception 'fixture requires exact canonical post-767 release family';end if;
end $baseline$;
select lives_ok({block},'canonical state accepts actual 770 block');
select is((select count(*) from canonical_before b join private.api_capability_grants m on to_regprocedure(m.routine_identity)::oid=b.oid where m.ctid::text<>b.row_tid),0::bigint,'canonical replay performs zero row writes');

-- Read-only Main before-state has canonical flags, EDGE-REL-01 except Bundle EDGE-ACTOR-01.
update private.api_capability_grants m set capability_id=case when p.proname='get_lcia_result_calculation_bundle' then 'EDGE-ACTOR-01' else 'EDGE-REL-01' end
from pg_proc p where p.oid=to_regprocedure(m.routine_identity) and p.oid in(select oid from canonical_before);
select lives_ok({previous},'actual 767 migration accepts observed Main before-state');
create temporary table main_after_767 as select m.ctid::text row_tid,to_regprocedure(m.routine_identity)::oid oid from private.api_capability_grants m where to_regprocedure(m.routine_identity)::oid in(select oid from canonical_before);
select lives_ok({block},'Main before-state through 767 is canonical for 770');
select is((select count(*) from main_after_767 b join private.api_capability_grants m on to_regprocedure(m.routine_identity)::oid=b.oid where m.ctid::text<>b.row_tid),0::bigint,'770 performs zero writes after actual 767 Main path');

delete from private.api_capability_grants m where to_regprocedure(m.routine_identity)::oid in(select oid from canonical_before);
{old_body}
select ok((select count(*)=11 and count(distinct to_regprocedure(routine_identity))=11 and bool_and(capability_id='CLI-RPC-01' and not allow_anon and allow_authenticated and not allow_service_role)
from private.api_capability_grants where to_regprocedure(routine_identity)::oid in(select oid from canonical_before)), 'actual frozen fallback reproduces exact observed legacy vector');
create temporary table legacy_before as select to_regprocedure(m.routine_identity)::oid oid,m.ctid::text row_tid from private.api_capability_grants m where to_regprocedure(m.routine_identity)::oid in(select oid from canonical_before);
create temporary table others_before as select to_jsonb(m) row,m.ctid::text row_tid from private.api_capability_grants m where not exists(select 1 from canonical_before b where b.oid=to_regprocedure(m.routine_identity)::oid);
select lives_ok({block},'actual 770 repairs only recognized whole legacy vector');
select ok(not exists(select 1 from canonical_before b join private.api_capability_grants m on to_regprocedure(m.routine_identity)::oid=b.oid where
(m.capability_id,m.allow_anon,m.allow_authenticated,m.allow_service_role) is distinct from (b.capability_id,b.allow_anon,b.allow_authenticated,b.allow_service_role)), 'eleven canonical classifications and role flags restored');
select is((select count(*) from legacy_before b join private.api_capability_grants m on to_regprocedure(m.routine_identity)::oid=b.oid where m.ctid::text<>b.row_tid),4::bigint,'known legacy repair changes exactly four rows');
select ok(not exists(select 1 from others_before b left join private.api_capability_grants m on m.routine_identity=b.row->>'routine_identity' where to_jsonb(m) is distinct from b.row or m.ctid::text is distinct from b.row_tid),'all other manifest rows remain byte and tuple unchanged');
select ok(not exists((select row from client_before except select to_jsonb(r) from private.oauth_client_registry r) union all (select to_jsonb(r) from private.oauth_client_registry r except select row from client_before))
and not exists((select row from grants_before except select to_jsonb(r) from private.oauth_client_capability_grants r) union all (select to_jsonb(r) from private.oauth_client_capability_grants r except select row from grants_before)), 'client registrations and grants remain unchanged');
select ok((select bool_and(p.proacl is not distinct from b.proacl) from canonical_before b join pg_proc p on p.oid=b.oid),'all actual ACLs unchanged');
create temporary table replay_before as select to_regprocedure(m.routine_identity)::oid oid,m.ctid::text row_tid from private.api_capability_grants m where to_regprocedure(m.routine_identity)::oid in(select oid from canonical_before);
select lives_ok({block},'repaired state replays actual block idempotently');
select is((select count(*) from replay_before b join private.api_capability_grants m on to_regprocedure(m.routine_identity)::oid=b.oid where m.ctid::text<>b.row_tid),0::bigint,'repaired replay performs zero row writes');

update private.api_capability_grants set capability_id='UNKNOWN-770' where to_regprocedure(routine_identity)='api.assert_lca_release_manager()'::regprocedure;
select throws_ok({block},'P0001','Release capability manifest has an unrecognized prior state','unknown capability refuses mutation');
{reset}
update private.api_capability_grants set allow_anon=false,allow_service_role=false where to_regprocedure(routine_identity)='api.get_current_lca_release()'::regprocedure;
select throws_ok({block},'P0001','Release capability manifest has an unrecognized prior state','mixed canonical and legacy vectors refuse mutation');
{reset}
delete from private.api_capability_grants where to_regprocedure(routine_identity)='api.assert_lca_release_manager()'::regprocedure;
select throws_ok({block},'P0001','Release capability manifest is incomplete or duplicated','missing manifest target refuses mutation');
insert into private.api_capability_grants select routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role from canonical_before where oid='api.assert_lca_release_manager()'::regprocedure::oid;
insert into private.api_capability_grants select 'api."get_current_lca_release"()',capability_id,allow_anon,allow_authenticated,allow_service_role from canonical_before where oid='api.get_current_lca_release()'::regprocedure::oid;
select throws_ok({block},'P0001','Release capability manifest is incomplete or duplicated','duplicate semantic identity refuses mutation');
delete from private.api_capability_grants where to_regprocedure(routine_identity)='api.assert_lca_release_manager()'::regprocedure;
select throws_ok({block},'P0001','Release capability manifest is incomplete or duplicated','balanced missing and duplicate refuses mutation');
delete from private.api_capability_grants where routine_identity='api."get_current_lca_release"()';
insert into private.api_capability_grants select routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role from canonical_before where oid='api.assert_lca_release_manager()'::regprocedure::oid;
grant execute on function api.assert_lca_release_manager() to anon;
select throws_ok({block},'P0001','Release function ACL differs from canonical contract','actual external ACL drift refuses metadata repair');
revoke execute on function api.assert_lca_release_manager() from anon;
grant execute on function api.get_current_lca_release() to public;
select throws_ok({block},'P0001','Release function ACL differs from canonical contract','PUBLIC grant drift refuses even when three role flags still match');
revoke execute on function api.get_current_lca_release() from public;
alter function api.assert_lca_release_manager() rename to assert_lca_release_manager_770_test;
select throws_ok({block},'P0001','Release manifest target routine is missing','missing exact routine refuses mutation');
alter function api.assert_lca_release_manager_770_test() rename to assert_lca_release_manager;
select ok(not exists(select 1 from canonical_before b join private.api_capability_grants m on to_regprocedure(m.routine_identity)::oid=b.oid where
(m.capability_id,m.allow_anon,m.allow_authenticated,m.allow_service_role) is distinct from (b.capability_id,b.allow_anon,b.allow_authenticated,b.allow_service_role)), 'all refusal probes leave restored canonical manifest intact');
select * from finish();
rollback;
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-container", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"supabase_db_database-engine(?:-[a-z0-9-]+)?", args.local_container):
        parser.error("requires an explicitly owned local Database container")
    result = subprocess.run(["docker", "exec", "-i", args.local_container, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"], input=test_sql(), capture_output=True, text=True, timeout=90)
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    passed = re.findall(r"(?m)^ok ([0-9]+)\b", result.stdout)
    return 0 if result.returncode == 0 and passed == [str(i) for i in range(1, 24)] and not re.search(r"(?m)^not ok\b", result.stdout) else 1


if __name__ == "__main__":
    raise SystemExit(main())
