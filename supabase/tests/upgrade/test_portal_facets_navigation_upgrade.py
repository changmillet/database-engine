#!/usr/bin/env python3
"""Database #864: guarded local upgrade and committed visibility qualification.

The exact task-owned local PG17.11 container is the only accepted target. Real
source INSERTs and unchanged source/settings/projection hashes qualify upgrade
correctness. Default upgrade proof rolls back. Optional committed visibility
retains real fixtures for an owned reset; optional direct-projection volume
timing is separate and never substitutes for real writers. No hosted DSN.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time
import uuid

# This harness owns only its explicit evidence paths, including during imports.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[3]
BENCHMARK = ROOT / 'scripts/benchmark_portal_facets_navigation.py'
SPEC = importlib.util.spec_from_file_location('portal_facets_navigation_benchmark', BENCHMARK)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)

CANDIDATE = ROOT / 'supabase/migrations/20261025052607_optimize_portal_facets_navigation.sql'
FIXTURE = ROOT / 'supabase/tests/20261010_portal_display_readers.sql'
TARGETS = ('display_navigation_matched_versions_v1', 'display_catalog_facets_v3_impl',
           'display_navigation_impl_v1', 'portal_display_brand_facets_v1')
GUARD_STATE = '55000'
GUARD_MESSAGE = 'Display facets cutover projection coverage or facts drifted'
ROLE_GUARD_MESSAGE = 'Display facets cutover requires an RLS-bypassing migration role'
CHECK_LABELS = frozenset(('reject-missing-navigation', 'reject-missing-facet',
    'reject-navigation-facts', 'reject-facet-text-facts', 'reject-facet-state',
    'reject-original-v1-orphan', 'reject-non-bypass-role', 'injected-mid-upgrade'))


def split_statements(source: str) -> list[str]:
    """Split top-level SQL without splitting function bodies, strings or comments."""
    result: list[str] = []
    start = i = 0
    quoted: str | None = None
    escape_string = False
    block_depth = 0
    line_comment = False
    while i < len(source):
        if line_comment:
            if source[i] == '\n':
                line_comment = False
            i += 1
            continue
        if block_depth:
            if source.startswith('/*', i):
                block_depth += 1
                i += 2
            elif source.startswith('*/', i):
                block_depth -= 1
                i += 2
            else:
                i += 1
            continue
        if quoted:
            if source.startswith(quoted, i):
                if quoted in ("'", '"') and source.startswith(quoted * 2, i):
                    i += 2
                    continue
                i += len(quoted)
                quoted = None
                escape_string = False
            elif quoted == "'" and escape_string and source[i] == '\\':
                i += 2
            else:
                i += 1
            continue
        if source.startswith('--', i):
            line_comment = True
            i += 2
        elif source.startswith('/*', i):
            block_depth = 1
            i += 2
        elif source[i] in ("'", '"'):
            quoted = source[i]
            escape_string = quoted == "'" and i > 0 and source[i - 1].lower() == 'e' and (
                i < 2 or not (source[i - 2].isalnum() or source[i - 2] in '_$'))
            i += 1
        elif source[i] == '$' and (match := re.match(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$', source[i:])):
            quoted = match.group()
            i += len(quoted)
        elif source[i] == ';':
            result.append(source[start:i + 1])
            i += 1
            start = i
        else:
            i += 1
    if quoted or block_depth:
        raise ValueError('Unterminated SQL quote/comment in migration')
    if statement_code(source[start:]):
        raise ValueError('Unterminated final SQL statement')
    return result


def statement_code(statement: str) -> str:
    """Remove leading comments for top-level command classification only."""
    while True:
        statement = statement.lstrip()
        if statement.startswith('--'):
            statement = statement.partition('\n')[2]
        elif statement.startswith('/*'):
            depth, offset = 1, 2
            while depth and offset < len(statement):
                if statement.startswith('/*', offset):
                    depth += 1
                    offset += 2
                elif statement.startswith('*/', offset):
                    depth -= 1
                    offset += 2
                else:
                    offset += 1
            if depth:
                raise ValueError('Unterminated leading SQL comment')
            statement = statement[offset:]
        else:
            return statement.strip()


def migration_statements(source: str) -> list[str]:
    statements = split_statements(source)
    if len(statements) < 3 or statement_code(statements[0]).lower() != 'begin;' or statement_code(statements[-1]).lower() != 'commit;':
        raise ValueError('Expected one complete BEGIN/COMMIT migration')
    statements = statements[1:-1]
    if any(re.match(r'(?:begin|commit|rollback|start\s+transaction)\b', statement_code(s), re.I)
           for s in statements):
        raise ValueError('Unexpected top-level transaction command')
    return statements


def execute_statements(statements: list[str]) -> str:
    return '\n'.join('execute ' + bench.literal(statement) + ';' for statement in statements)


def source_fixture() -> str:
    marker = 'select is((select count(*)::integer from private.display_catalog_search_rows_v2)'
    source = FIXTURE.read_text()
    if source.count(marker) != 1:
        raise ValueError('Exact source-writer fixture boundary required')
    prefix = source.split(marker)[0]
    prefix = re.sub(r'^begin;\s*', '', prefix, count=1, flags=re.M | re.I)
    prefix = prefix.replace('select extensions.no_plan();', '')
    return prefix + """
-- Additional exact versions exercise history, literal escaping, mixed brands,
-- nullable facts and provincial geography through the REAL source/settings
-- writers. No trigger is disabled in this correctness fixture.
insert into public.processes(id,version,state_code,json) values
 ('80700000-0000-4000-8000-000000000101','03.00.000',20,
  jsonb_set(jsonb_set(pg_temp.portal_versions_process_payload('Historical %_ process864','03.00.000'),
   '{processDataSet,processInformation,geography,locationOfOperationSupplyOrProduction,@location}',
   '"CN-AH-HFE"'),'{processDataSet,processInformation,time,common:referenceYear}','"2022"'));
insert into public.flows(id,version,state_code,json) values
 ('80700000-0000-4000-8000-000000000103','02.00.000',200,
  pg_temp.portal_versions_flow_payload('Historical %_ flow864','02.00.000'));
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand) values
 ('process','80700000-0000-4000-8000-000000000101','03.00.000',true,'uslci'),
 ('flow','80700000-0000-4000-8000-000000000103','02.00.000',true,'worldsteel');
set constraints all immediate;
update private.portal_display_rollout set mode='display';
"""


def catalog_query() -> str:
    targets = ','.join(bench.literal(name) for name in TARGETS)
    return f"""select jsonb_build_object(
 'routines',(select md5(coalesce(jsonb_agg(jsonb_build_array(p.oid,n.nspname,p.proname,
   to_jsonb(p)-'prosrc'-'prosqlbody',case when n.nspname='private' and p.proname in ({targets})
   then null else pg_get_functiondef(p.oid) end) order by p.oid)::text,''))
   from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('api','private','public','util','archive') and p.prokind in ('f','p')),
 'targetDefinitions',(select jsonb_object_agg(p.proname,md5(pg_get_functiondef(p.oid)))
   from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='private' and p.proname in ({targets})),
 'relations',(select md5(coalesce(jsonb_agg(jsonb_build_array(c.oid,c.relname,c.relkind,c.relowner,c.relacl,
   c.relrowsecurity,c.relforcerowsecurity,c.reloptions,c.relpersistence,c.relam,c.relreplident,
   case when c.relkind in ('v','m') then pg_get_viewdef(c.oid) end,
   (select jsonb_agg(to_jsonb(a) order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0),
   (select jsonb_agg(jsonb_build_array(x.oid,x.conname,pg_get_constraintdef(x.oid),x.convalidated) order by x.oid) from pg_constraint x where x.conrelid=c.oid),
   (select jsonb_agg(jsonb_build_array(i.indexrelid,pg_get_indexdef(i.indexrelid),to_jsonb(i)) order by i.indexrelid) from pg_index i where i.indrelid=c.oid),
   (select jsonb_agg(to_jsonb(p) order by p.oid) from pg_policy p where p.polrelid=c.oid),
   (select jsonb_agg(jsonb_build_array(t.oid,pg_get_triggerdef(t.oid),t.tgenabled) order by t.oid) from pg_trigger t where t.tgrelid=c.oid)
   ) order by c.oid)::text,'')) from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname in ('api','private','public','util','archive')),
 'schemas',(select md5(jsonb_agg(jsonb_build_array(oid,nspname,nspowner,nspacl) order by oid)::text)
   from pg_namespace where nspname in ('api','private','public','util','archive')),
 'roles',(select md5(jsonb_agg(jsonb_build_array(oid,rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,
   rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolvaliduntil,rolconfig) order by oid)::text) from pg_roles),
 'roleMemberships',(select md5(coalesce(jsonb_agg(to_jsonb(m) order by m.oid)::text,'')) from pg_auth_members m),
 'manifest',(select to_jsonb(m) from private.portal_display_contract_manifest m where singleton))"""


def snapshot_helpers() -> str:
    return """
create temp table upgrade_checks(label text primary key,evidence jsonb not null);
create temp table upgrade_snapshots(label text primary key,value jsonb not null);
create temp table upgrade_responses(phase text,label text,payload jsonb,sqlstate text,primary key(phase,label));
grant select,insert on upgrade_responses to anon;
create function pg_temp.data_digest(rel regclass) returns jsonb language plpgsql as $$
declare result jsonb;begin
 execute format('select jsonb_build_object(''rows'',count(*),''sha'',md5(coalesce(string_agg(md5(to_jsonb(r)::text),'''' order by md5(to_jsonb(r)::text)),''''))) from %s r',rel) into result;
 return result;
end$$;
create function pg_temp.upgrade_snapshot() returns jsonb language plpgsql as $snapshot$
declare catalog jsonb;data jsonb;begin
 """ + catalog_query() + """ into catalog;
 select jsonb_object_agg(c.oid::regclass::text,pg_temp.data_digest(c.oid)) into data
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where c.relkind in ('r','p') and (n.nspname='public' or (n.nspname='private' and
   (c.relname like 'display_%' or c.relname in ('dataset_display_settings','portal_display_rollout',
    'portal_display_derivation_contract','portal_navigation_node_v1'))));
 return catalog||jsonb_build_object('data',data);
end$snapshot$;
create function pg_temp.verify_upgrade() returns void language plpgsql as $$
declare expected jsonb;actual jsonb;begin
 select value into strict expected from upgrade_snapshots where label='baseline';
 actual:=pg_temp.upgrade_snapshot();
 if (expected-'targetDefinitions'-'manifest') is distinct from (actual-'targetDefinitions'-'manifest') then
  raise exception 'Source/settings/projection, non-target routines or metadata/roles/RLS/index drift';
 end if;
 perform private.portal_display_assert_contract_v1();
end$$;
create function pg_temp.upgrade_probe(p_phase text,p_label text,q text,expected_state text default null)
returns void language plpgsql as $$
declare payload jsonb;failure text;begin
 begin execute q into payload;exception when query_canceled then failure:=sqlstate;when others then failure:=sqlstate;end;
 if failure is distinct from expected_state then raise exception 'Unexpected RPC SQLSTATE in % %: %',p_phase,p_label,failure;end if;
 insert into upgrade_responses values(p_phase,p_label,payload,failure);
end$$;
grant execute on function pg_temp.upgrade_probe(text,text,text,text) to anon;
"""


def probes(phase: str) -> tuple[str, int]:
    sql = "set local statement_timeout='8s';set local role anon;\n"
    count = 0
    scopes = ('tiangong_lca', 'bafu', 'bafu,tiangong_lca,uslci,worldsteel', 'worldsteel')
    shapes = [('empty', '', {}), ('literal', '%_', {}), ('history', 'historical', {}),
              ('one', 'v', {}), ('uuid', '80700000-0000-4000-8000-000000000101', {}),
              ('cas', '50-00-0', {}), ('zero', 'absent864', {}),
              ('classic', '', {'geography': 'cn', 'referenceYearFrom': 2024}),
              ('subtree', '', {'geographyNodeId': 'geo:cn'}),
              ('direct', '', {'geographyNodeId': 'geo:cn', 'geographyScope': 'direct'}),
              ('province', '', {'geographyNodeId': 'geo:cn-ah-hfe'}),
              ('brand', '', {'brand': 'bafu'})]
    for scope in scopes:
        brands = 'array[' + ','.join(bench.literal(x) for x in scope.split(',')) + ']'
        for kind in ('all', 'process', 'flow'):
            for label, query, filters in shapes:
                q = f"select api.portal_facets_v4({brands},{bench.literal(kind)},{bench.literal(query)},{bench.literal(json.dumps(filters))}::jsonb)"
                sql += f"select pg_temp.upgrade_probe({bench.literal(phase)},{bench.literal(scope+':facets:'+kind+':'+label)},{bench.literal(q)});\n"
                count += 1
        for label, query, filters in shapes:
            for dimension, parent in (('geography', 'null'), ('classification', "'class:isic'")):
                q = f"select api.portal_navigation_v2({brands},'all',{bench.literal(query)},{bench.literal(json.dumps(filters))}::jsonb,{bench.literal(dimension)},{parent},null,1)"
                name = scope + ':navigation:' + dimension + ':' + label
                sql += f"select pg_temp.upgrade_probe({bench.literal(phase)},{bench.literal(name)},{bench.literal(q)});\n"
                count += 1
        first_label = scope + ':navigation:geography:empty'
        cursor = "(select payload->>'nextCursor' from upgrade_responses where phase='baseline' and label=" + bench.literal(first_label) + ')'
        q = f"select api.portal_navigation_v2({brands},'all','','{{}}'::jsonb,'geography',null,{cursor},1)"
        sql += f"select pg_temp.upgrade_probe({bench.literal(phase)},{bench.literal(scope+':navigation:page2-baseline-cursor')},{bench.literal(q)});\n"
        count += 1
    for label, query in (
        ('bad-brand', "select api.portal_facets_v4(array['unknown'],'all','')"),
        ('bad-facet-kind', "select api.portal_facets_v4(array['tiangong_lca'],'unknown','')"),
        ('bad-node', "select api.portal_navigation_v2(array['tiangong_lca'],'all','','{}','geography','geo:absent-864')"),
        ('bad-cursor', "select api.portal_navigation_v2(array['tiangong_lca'],'all','','{}','geography',null,'invalid',1)")):
        sql += f"select pg_temp.upgrade_probe({bench.literal(phase)},{bench.literal(label)},{bench.literal(query)},'22023');\n"
        count += 1
    return sql + 'reset role;\n', count


def rejection(label: str, setup: str, statements: list[str], state: str, message: str,
              evidence_sql: str = "'{}'::jsonb") -> str:
    """Nested transactions independently roll back migration and corruption."""
    return f"""
do $rejection$
declare original jsonb:=pg_temp.upgrade_snapshot();corrupted jsonb;rejected boolean:=false;
 caught_state text;caught_message text;
begin
 begin
  {setup}
  corrupted:=pg_temp.upgrade_snapshot();
  begin
   {execute_statements(statements)}
  exception when others then
   get stacked diagnostics caught_state=returned_sqlstate,caught_message=message_text;
   if caught_state is distinct from {bench.literal(state)} or caught_message is distinct from {bench.literal(message)} then raise;end if;
   rejected:=true;
  end;
  if not rejected then raise exception 'Expected migration rejection did not occur: {label}';end if;
  if pg_temp.upgrade_snapshot() is distinct from corrupted then raise exception 'Rejected migration leaked state: {label}';end if;
  raise exception using errcode='P0864',message='rollback #864 rejection fixture';
 exception when sqlstate 'P0864' then
  if sqlerrm<>'rollback #864 rejection fixture' then raise;end if;
 end;
 if pg_temp.upgrade_snapshot() is distinct from original then raise exception 'Rejection fixture rollback leaked state: {label}';end if;
 insert into upgrade_checks values({bench.literal(label)},jsonb_build_object('sqlstate',caught_state,'message',caught_message,'migrationRolledBack',true,'fixtureRolledBack',true)||{evidence_sql});
end$rejection$;
"""


def cutover_guard(statements: list[str]) -> str:
    guards = [s for s in statements if '$display_facets_cutover_guard$' in s]
    if len(guards) != 1:
        raise ValueError('Exactly one named cutover guard required')
    return guards[0]


def old_three_way_guard(guard: str) -> str:
    """Only remove the fourth coverage leg to prove the P1 counterexample."""
    old, joins = re.subn(r'\s+full\s+join\s+private\.display_catalog_search_rows_v1\s+as\s+original\s+'
        r'using\s*\(dataset_kind,\s*id,\s*version\)', '', guard, flags=re.I)
    old, predicates = re.subn(r'\s+or\s+original\.id\s+is\s+null', '', old, flags=re.I)
    if joins != 1 or predicates != 1:
        raise ValueError('Exact original-V1 fourth guard leg required for P1 counterexample')
    return old


def build_real_sql(predecessor: dict, statements: list[str]) -> tuple[str, int]:
    sql = "begin;set local statement_timeout='60s';set local lock_timeout='5s';set local work_mem='4MB';\n"
    sql += "do $$begin if not pg_try_advisory_xact_lock(864,1) then raise exception 'Another #864 fixture owns this database';end if;end$$;\n"
    sql += bench.definitions_sql(predecessor) + source_fixture() + snapshot_helpers()
    sql += "insert into upgrade_snapshots values('baseline',pg_temp.upgrade_snapshot());\n"
    sql += "do $$begin if (select count(*) from private.display_catalog_search_rows_v1)<>5 or (select count(*) from private.display_catalog_search_rows_v2)<>3 then raise exception 'Real source fixture cardinality drift';end if;end$$;\n"
    before, count = probes('baseline')
    sql += before
    sql += "do $$begin if exists(select 1 from upgrade_responses where label like '%:navigation:geography:empty' and payload->>'nextCursor' is null) then raise exception 'Actual baseline continuation cursor required';end if;end$$;\n"
    key = "dataset_kind='process' and id='80700000-0000-4000-8000-000000000101' and version='01.00.000'"
    corruptions = {
        'reject-missing-navigation': 'delete from private.display_navigation_versions_v1 where ' + key + ';',
        'reject-missing-facet': 'delete from private.display_catalog_facet_rows_v1 where ' + key + ';',
        'reject-navigation-facts': "update private.display_navigation_versions_v1 set source='drift864' where " + key + ';',
        'reject-facet-text-facts': "update private.display_catalog_facet_rows_v1 set facet_reference_year='02024' where " + key + ';',
        'reject-facet-state': 'update private.display_catalog_facet_rows_v1 set state_code=200 where ' + key + ';',
    }
    for label, setup in corruptions.items():
        sql += rejection(label, setup, statements, GUARD_STATE, GUARD_MESSAGE)
    orphan_setup = f"""
delete from private.display_catalog_search_rows_v2 where {key};
delete from private.display_catalog_facet_rows_v1 where {key};
do $$begin
 if not exists(select 1 from private.display_catalog_search_rows_v1 where {key})
  or exists(select 1 from private.display_catalog_search_current_v2 where {key})
  or exists(select 1 from private.display_navigation_versions_v1 where {key})
  or exists(select 1 from private.display_catalog_facet_rows_v1 where {key}) then
  raise exception 'Original-V1 orphan counterexample was not constructed';
 end if;
end$$;
""" + old_three_way_guard(cutover_guard(statements))
    sql += rejection('reject-original-v1-orphan', orphan_setup, statements, GUARD_STATE, GUARD_MESSAGE,
        "jsonb_build_object('oldThreeWayGuardAccepted',true,'originalV1Present',true,'currentNavigationFacetAbsent',true)")
    # Role switching belongs INSIDE the failing migration subtransaction so the
    # exception restores the administrator before either snapshot is read.
    role_setup = """do $$begin
 if not exists(select 1 from pg_roles where rolname='portal_display_executor' and not rolsuper and not rolbypassrls) then
  raise exception 'An existing exact non-BYPASSRLS executor role is required';
 end if;
end$$;"""
    sql += rejection('reject-non-bypass-role', role_setup,
        ['set local role portal_display_executor;'] + statements, GUARD_STATE, ROLE_GUARD_MESSAGE,
        "jsonb_build_object('role','portal_display_executor','roleOrAclMutation',false)")
    replaced = 0
    partial = []
    for statement in statements:
        partial.append(statement)
        if re.match(r'create\s+or\s+replace\s+function\b', statement_code(statement), re.I):
            replaced += 1
            if replaced == 2:
                break
    if replaced != 2:
        raise ValueError('At least two target function replacements required for partial-upgrade injection')
    partial.append("do $$begin raise exception using errcode='P0865',message='expected #864 mid-upgrade failure';end$$;")
    sql += rejection('injected-mid-upgrade', '', partial, 'P0865', 'expected #864 mid-upgrade failure')
    migration = '\n'.join(statements)
    sql += migration + '\nselect pg_temp.verify_upgrade();\n'
    sql += "insert into upgrade_snapshots values('candidate',pg_temp.upgrade_snapshot());\n"
    after, after_count = probes('candidate')
    assert count == after_count
    sql += after + migration + '\nselect pg_temp.verify_upgrade();\n'
    sql += """
do $$begin
 if pg_temp.upgrade_snapshot() is distinct from (select value from upgrade_snapshots where label='candidate') then raise exception 'Repeat application drift';end if;
 if exists(select 1 from upgrade_responses b full join upgrade_responses c on b.label=c.label and c.phase='candidate'
  where b.phase='baseline' and (c.label is null or b.payload is distinct from c.payload or b.sqlstate is distinct from c.sqlstate)) then raise exception 'Complete API JSON or SQLSTATE drift';end if;
end$$;
select jsonb_build_object('checks',(select jsonb_object_agg(label,evidence) from upgrade_checks),
 'snapshots',(select jsonb_object_agg(label,value) from upgrade_snapshots),
 'responses',(select jsonb_agg(to_jsonb(r) order by phase,label) from upgrade_responses r),
 'realSourceRows',(select jsonb_build_object('processes',count(*)) from public.processes)||
   (select jsonb_build_object('flows',count(*)) from public.flows),
 'sourceWriterTriggersEnabled',not exists(select 1 from pg_trigger where not tgisinternal and tgenabled='D'
  and tgrelid in ('public.processes'::regclass,'public.flows'::regclass,'private.dataset_display_settings'::regclass)));
rollback;
"""
    return sql, count


def build_synthetic_sql(predecessor: dict, statements: list[str], processes: int, flows: int) -> str:
    guard = cutover_guard(statements)
    sql = bench.fixture(processes, flows, 3072) + bench.definitions_sql(predecessor) + snapshot_helpers()
    sql += "insert into upgrade_snapshots values('baseline',pg_temp.upgrade_snapshot());set local statement_timeout='60s';create temp table guard_timing(started timestamptz);insert into guard_timing values(clock_timestamp());\n"
    sql += guard + "\nselect jsonb_build_object('guardElapsedMs',extract(epoch from clock_timestamp()-started)*1000) from guard_timing;\n"
    sql += '\n'.join(statements) + '\nselect pg_temp.verify_upgrade();\n'
    sql += "select jsonb_build_object('snapshot',pg_temp.upgrade_snapshot(),'classification','synthetic direct projections: guard volume only; not source-writer proof');rollback;\n"
    return sql


def execute_case(sql: str, stem: Path) -> tuple[list[dict], str]:
    stem.with_suffix('.sql').write_text(sql)
    completed = bench.run(sql)
    stem.with_suffix('.log').write_text(completed.stdout + '\n' + completed.stderr)
    if completed.returncode:
        raise RuntimeError(f'psql exited {completed.returncode}; inspect {stem.with_suffix(".log")}')
    records = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
    return records, bench.sha(sql)


def visibility_run(application: str, sql: str, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    """Name at startup and normalize metadata deparsing across sessions."""
    return subprocess.run(['docker', 'exec', '-i', '-e', 'PGAPPNAME=' + application,
        bench.CONTAINER, 'psql', '-X', '-h', '/var/run/postgresql', '-U', 'supabase_admin',
        '-d', 'postgres', '-Atq', '-v', 'ON_ERROR_STOP=1'], input="set search_path='';\n" + sql, text=True,
        capture_output=True, timeout=timeout)


class VisibilitySession:
    """One named local socket client; stdout markers synchronize actual SQL."""

    def __init__(self, application: str):
        self.application = application
        self.lines: list[str] = []
        self.errors: list[str] = []
        self.events: queue.Queue[str | None] = queue.Queue()
        self.process = subprocess.Popen(['docker', 'exec', '-i', '-e', 'PGAPPNAME=' + application, bench.CONTAINER,
            'psql', '-X', '-h', '/var/run/postgresql', '-U', 'supabase_admin',
            '-d', 'postgres', '-Atq', '-v', 'ON_ERROR_STOP=1'], text=True,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=1)

        def collect(stream, output, events=None):
            for line in stream:
                output.append(line)
                if events is not None:
                    events.put(line.rstrip('\n'))
            if events is not None:
                events.put(None)

        self.readers = [threading.Thread(target=collect,
            args=(self.process.stdout, self.lines, self.events), daemon=True),
            threading.Thread(target=collect, args=(self.process.stderr, self.errors), daemon=True)]
        for reader in self.readers:
            reader.start()
        self.send('set application_name=' + bench.literal(application) + ';')

    def send(self, sql: str) -> None:
        assert self.process.stdin
        self.process.stdin.write(sql + '\n')
        self.process.stdin.flush()

    def marker(self, prefix: str, timeout: int = 60) -> str:
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self.events.get(timeout=max(0.001, deadline - time.monotonic()))
            except queue.Empty as exc:
                raise RuntimeError('SQL marker timeout: ' + prefix) from exc
            if line is None:
                raise RuntimeError('Local client exited before marker: ' + prefix)
            if line.startswith(prefix):
                return line
            if time.monotonic() >= deadline:
                raise RuntimeError('SQL marker timeout: ' + prefix)

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.send('\\q')
            except (BrokenPipeError, OSError):
                pass
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=60)
        for reader in self.readers:
            reader.join(timeout=5)


def visibility_queries() -> dict[str, str]:
    """Complete DTOs plus unaffected-brand controls, all through public RPCs."""
    scopes = {'tiangong': "array['tiangong_lca']",
              'combined': "array['bafu','tiangong_lca','uslci','worldsteel']"}
    result = {}
    for label, brands in scopes.items():
        result['facets_' + label] = f"api.portal_facets_v4({brands},'all','','{{}}')"
        result['facets_process_' + label] = f"api.portal_facets_v4({brands},'process','visible','{{}}')"
        result['navigation_geography_' + label] = f"api.portal_navigation_v2({brands},'all','','{{}}','geography',null,null,100)"
        result['navigation_classification_' + label] = f"api.portal_navigation_v2({brands},'process','','{{}}','classification','class:isic',null,20)"
    result['facets_bafu_control'] = "api.portal_facets_v4(array['bafu'],'flow','50-00-0','{}')"
    return result


def visibility_read_sql() -> str:
    fields = ','.join(bench.literal(label) + ',' + query for label, query in visibility_queries().items())
    return ("set local statement_timeout='8s';set local role anon;select jsonb_build_object("
            "'readerRole',current_user,'readerPid',pg_backend_pid(),"
            "'readerApplication',current_setting('application_name'),'responses',jsonb_build_object("
            + fields + '));reset role;')


def committed_visibility(args, context: dict, inspected: dict, owner: str, base: str,
                         migration: str, statements: list[str], predecessor: dict,
                         initial_catalog: dict) -> int:
    """Committed local fixtures are deliberately retained for an owned reset.

    A controller holds both the existing #864 exclusive fixture lock and a
    nonce-specific gate. The settings writer changes real display state, then
    blocks at that gate before COMMIT. An observer proves the writer's actual
    advisory wait and blocker PID before/after a separate anonymous read. No
    sleep interval substitutes for transaction ordering.
    """
    nonce = args.visibility_nonce
    prefix = 'portal864-cv-' + nonce + '-'
    gate = int(bench.sha(nonce)[:8], 16) % 2147483645 + 2
    stem = args.report.with_name(args.report.stem + '-visibility')
    transcript: list[str] = []
    logs: list[str] = []
    ordinal = 0
    controller = writer = None
    owned_pids: dict[str, int] = {}
    installed_catalog = None
    setup_committed = False
    report = {'schemaVersion': 'portal.facets-navigation-committed-visibility.v1',
        'passed': False, 'classification': 'local real settings writer, independent committed visibility; not load or hosted latency',
        'nonce': nonce, 'applicationNamePrefix': prefix, 'containerId': inspected['Id'],
        'dockerContext': context['Name'], 'ownerSha256': bench.sha(owner), 'baseCommit': base,
        'candidateSha256': bench.sha(migration), 'harnessSha256': bench.sha(Path(__file__).read_bytes()),
        'exclusiveFixtureLock': [864, 1], 'writerCommitGateLock': [864, gate],
        'requestBudget': '8s', 'writerPath': 'dataset_display_settings UPDATE with unchanged display writers enabled',
        'sourceUpdateBeforeHide': False, 'fixtureRetained': False, 'resetRequired': False,
        'baselineReplay': 'same committed data, transaction-only predecessor definitions and rollback',
        'cleanup': None}

    def call(label: str, sql: str, timeout: int = 120) -> list[dict]:
        nonlocal ordinal
        ordinal += 1
        application = prefix + label + '-' + str(ordinal)
        full = 'set application_name=' + bench.literal(application) + ";set search_path='';\n" + sql
        transcript.append('-- ' + label + '\n' + full + '\n')
        result = visibility_run(application, full, timeout)
        logs.append('-- ' + application + '\n' + result.stdout + '\n' + result.stderr)
        if result.returncode:
            raise RuntimeError('Local visibility client failed: ' + label)
        return [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]

    def capture(label: str, replay: bool = False) -> dict:
        sql = 'begin;set local work_mem=\'4MB\';\n'
        if replay:
            sql += bench.definitions_sql(predecessor)
        sql += visibility_read_sql() + '\nrollback;'
        rows = call(label, sql)
        if len(rows) != 1 or set(rows[0]) != {'readerRole', 'readerPid', 'readerApplication', 'responses'}:
            raise ValueError('Complete anonymous reader connection/response envelope required')
        row = rows[0]
        if row['readerRole'] != 'anon' or row['readerPid'] in owned_pids.values() or not row['readerApplication'].startswith(prefix):
            raise ValueError('An independent exact-nonce anonymous reader connection is required')
        if set(row['responses']) != set(visibility_queries()):
            raise ValueError('Complete unique anonymous visibility response required')
        report.setdefault('readerConnections', {})[label] = {key: row[key] for key in ('readerRole', 'readerPid', 'readerApplication')}
        return row['responses']

    def observe(label: str) -> dict:
        writer_app = bench.literal(prefix + 'writer')
        controller_pid = owned_pids[prefix + 'controller']
        writer_pid = owned_pids[prefix + 'writer']
        predicate = f"pid={writer_pid} and application_name={writer_app} and state='active' and wait_event_type='Lock' and lower(wait_event)='advisory' and {controller_pid}=any(pg_blocking_pids(pid))"
        sql = f"""do $wait$declare deadline timestamptz:=clock_timestamp()+interval '10 seconds';begin
 loop
  perform pg_stat_clear_snapshot();
  exit when exists(select 1 from pg_stat_activity where {predicate});
  if clock_timestamp()>deadline then raise exception 'Exact writer advisory wait was not observed';end if;
 end loop;
end$wait$;
select jsonb_build_object('pid',pid,'application',application_name,'state',state,
 'waitEventType',wait_event_type,'waitEvent',wait_event,'blockers',pg_blocking_pids(pid))
from pg_stat_activity where {predicate};"""
        rows = call(label, sql, 30)
        if len(rows) != 1:
            raise ValueError('One exact blocked writer required')
        return rows[0]

    args.report.parent.mkdir(parents=True, exist_ok=True)
    try:
        controller = VisibilitySession(prefix + 'controller')
        control_sql = f"""do $$begin if not pg_try_advisory_lock(864,1) then raise exception 'Another #864 fixture owns this database';end if;end$$;
select pg_advisory_lock(864,{gate});
select 'CONTROLLER_READY:'||pg_backend_pid();"""
        transcript.append('-- controller\n' + control_sql)
        controller.send(control_sql)
        owned_pids[prefix + 'controller'] = int(controller.marker('CONTROLLER_READY:').split(':')[1])
        # Repeat the empty guard AFTER acquiring the exclusive cross-connection
        # fixture lock so a competing benchmark cannot win a check/use race.
        checked = visibility_run(prefix + 'locked-empty-guard', bench.guard_sql(), 60)
        if checked.returncode or checked.stdout.strip().splitlines() != bench.empty_guard_expected():
            raise ValueError('Exclusive visibility setup requires the same empty owned PG17.11 database')
        util = call('original-util', "select jsonb_build_object('definition',pg_get_functiondef('util.invoke_edge_function(text,jsonb,integer)'::regprocedure));")[0]['definition']
        # pg_get_functiondef ends at the closing dollar quote, without a SQL
        # terminator. Keep restoration a complete statement before appending SET.
        util = util.rstrip().rstrip(';') + ';\n'
        seed = source_fixture().replace('create extension if not exists pgtap with schema extensions;', '')
        setup = "begin;set local statement_timeout='60s';set local work_mem='4MB';\n" + '\n'.join(statements) + seed + '\n' + util + "\nset local search_path='';select private.portal_display_assert_contract_v1();\n" + catalog_query() + ';commit;'
        rows = call('committed-setup', setup)
        setup_committed = True
        report['fixtureRetained'] = report['resetRequired'] = True
        if len(rows) != 1:
            raise ValueError('One committed candidate metadata snapshot required')
        installed_catalog = rows[0]
        if (installed_catalog | {'targetDefinitions': None, 'manifest': None}) != (initial_catalog | {'targetDefinitions': None, 'manifest': None}):
            raise ValueError('Committed setup changed unapproved permanent metadata or util definition')
        old = capture('old-candidate')
        report['oldResponses'] = old
        writer = VisibilitySession(prefix + 'writer')
        write_sql = f"""begin;set local statement_timeout='60s';
do $$begin
 update private.dataset_display_settings set is_visible=false
 where dataset_kind='process' and dataset_id='80700000-0000-4000-8000-000000000101'
  and dataset_version='01.00.000' and is_visible;
 if not found then raise exception 'Exact real display hide fixture missing';end if;
end$$;
select 'WRITER_MUTATED:'||pg_backend_pid();
select pg_advisory_xact_lock(864,{gate});
commit;
select 'WRITER_COMMITTED';
\\q"""
        transcript.append('-- real display writer\n' + write_sql)
        writer.send(write_sql)
        owned_pids[prefix + 'writer'] = int(writer.marker('WRITER_MUTATED:').split(':')[1])
        report['waitBeforeRead'] = observe('wait-before-reader')
        during = capture('uncommitted-reader')
        report['waitAfterRead'] = observe('wait-after-reader')
        if during != old:
            raise ValueError('Uncommitted real hide changed the independent anonymous response')
        report['uncommittedResponses'] = during
        controller.send(f"select pg_advisory_unlock(864,{gate});select 'GATE_RELEASED';")
        controller.marker('GATE_RELEASED')
        writer.marker('WRITER_COMMITTED')
        writer.close()
        new = capture('committed-reader')
        if old['navigation_geography_tiangong']['totals']['process'] != 1 or new['navigation_geography_tiangong']['totals']['process'] != 0:
            raise ValueError('Committed hide did not synchronously remove the exact visible Process')
        if old['facets_tiangong'] == new['facets_tiangong'] or old['facets_bafu_control'] != new['facets_bafu_control']:
            raise ValueError('Committed Facets hide or unaffected-brand control failed')
        replay = capture('predecessor-replay', replay=True)
        if replay != new:
            raise ValueError('Same committed data differs from transaction-only predecessor replay')
        report.update({'newResponses': new, 'predecessorReplayResponses': replay,
            'uncommittedReadEqualsOld': True, 'committedReadEqualsPredecessor': True,
            'immediateReadAfterObservedCommit': True, 'fullResponseComparisons': 2 * len(visibility_queries()),
            'utilInvocationDefinitionRestoredBeforeCommit': True, 'passed': True})
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        report['failure'] = str(exc)
    finally:
        report['ownedSessionPids'] = dict(owned_pids)
        # Never cancel an unrelated client: require the exact unique nonce/app,
        # and also its observed PID whenever the first marker supplied one.
        try:
            try:
                if writer is not None and writer.process.poll() is None:
                    pid = owned_pids.get(prefix + 'writer')
                    pid_guard = f'pid={pid} and ' if pid is not None else ''
                    # The nonce/application is known before the first marker;
                    # this also handles a failure before the PID is returned.
                    call('cancel-own-writer', f"select jsonb_build_object('terminated',coalesce(bool_and(pg_terminate_backend(pid)),true)) from pg_stat_activity where {pid_guard}application_name={bench.literal(prefix+'writer')};", 30)
                    writer.close()
            finally:
                if controller is not None:
                    controller.close()
            final = call('final-receipt', catalog_query() + ";select jsonb_build_object('nonceSessions',(select count(*) from pg_stat_activity where pid<>pg_backend_pid() and application_name like " + bench.literal(prefix+'%') + "),'fixtureExclusiveLockReleased',pg_try_advisory_xact_lock(864,1),'manifestValid',(select identity=private.portal_display_contract_identity_v1() from private.portal_display_contract_manifest where singleton),'processRows',(select count(*) from public.processes),'flowRows',(select count(*) from public.flows),'settingsRows',(select count(*) from private.dataset_display_settings),'writersEnabled',not exists(select 1 from pg_trigger where not tgisinternal and tgenabled='D' and tgrelid in ('public.processes'::regclass,'public.flows'::regclass,'private.dataset_display_settings'::regclass)));")
            if len(final) != 2:
                raise ValueError('Unique final metadata and retained-resource receipt required')
            metadata, receipt = final
            restored = installed_catalog is not None and metadata == installed_catalog
            retained = setup_committed or bool(receipt['processRows'] or receipt['flowRows'] or receipt['settingsRows'])
            report['fixtureRetained'] = retained
            report['resetRequired'] = retained
            report['cleanup'] = receipt | {'candidateMetadataAndFunctionsRestored': restored,
                'retained': retained, 'resetRequired': retained,
                'disposition': 'Retain committed task-local fixture for Main-owned reset; no container or volume was created'}
            if not (restored and receipt['nonceSessions'] == 0 and receipt['fixtureExclusiveLockReleased'] and receipt['manifestValid'] and receipt['writersEnabled']):
                report['passed'] = False
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
            report['passed'] = False
            report['cleanupFailure'] = str(exc)
        for session in (controller, writer):
            if session is not None:
                logs.append('-- ' + session.application + '\n' + ''.join(session.lines) + '\n' + ''.join(session.errors))
        stem.with_suffix('.sql').write_text('\n'.join(transcript))
        stem.with_suffix('.log').write_text('\n'.join(logs))
        report['sqlSha256'] = bench.sha(stem.with_suffix('.sql').read_bytes())
        report['logPath'] = str(stem.with_suffix('.log'))
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'report': str(args.report), 'passed': report['passed'],
        'fixtureRetained': report['fixtureRetained'], 'resetRequired': report['resetRequired'],
        'failure': report.get('failure'), 'cleanup': report['cleanup']}, indent=2))
    return int(not report['passed'])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True, choices=[bench.CONTAINER])
    parser.add_argument('--base-ref', required=True)
    parser.add_argument('--candidate', type=Path, default=CANDIDATE, choices=[CANDIDATE])
    parser.add_argument('--owner-file', type=Path, default=bench.OWNER, choices=[bench.OWNER])
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--synthetic-processes', type=int, default=0)
    parser.add_argument('--synthetic-flows', type=int, default=0)
    parser.add_argument('--committed-visibility', action='store_true',
        help='Commit real local fixtures, prove another writer/anonymous reader visibility, retain for owned reset')
    args = parser.parse_args()
    args.visibility_nonce = uuid.uuid4().hex[:12] if args.committed_visibility else None
    if not args.report.resolve().is_relative_to(bench.OWNER.parent.resolve()):
        parser.error('Evidence must stay in the task-owned private scratch directory')
    real_stem = args.report.with_name(args.report.stem + '-real')
    volume_stem = args.report.with_name(args.report.stem + '-synthetic')
    paths = [args.report] + [s.with_suffix(ext) for s in (real_stem, volume_stem) for ext in ('.sql', '.log')]
    if args.committed_visibility:
        visibility_stem = args.report.with_name(args.report.stem + '-visibility')
        paths = [args.report, visibility_stem.with_suffix('.sql'), visibility_stem.with_suffix('.log')]
    if len(set(paths)) != len(paths) or any(p.exists() for p in paths):
        parser.error('Report and SQL/log evidence paths must all be new')
    if not ((args.synthetic_processes == args.synthetic_flows == 0) or
            (20 <= args.synthetic_processes <= 20000 and 40 <= args.synthetic_flows <= 100000)):
        parser.error('Synthetic counts must both be omitted, or Process20..20000 and Flow40..100000')
    if args.committed_visibility and (args.synthetic_processes or args.synthetic_flows):
        parser.error('Committed visibility and synthetic volume timing are separate qualification modes')
    try:
        context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
        inspected = json.loads(subprocess.check_output(['docker', 'inspect', bench.CONTAINER], text=True))[0]
        owner = args.owner_file.read_text()
        bench.validate_target(context, inspected, owner)
        base = subprocess.check_output(['git', 'rev-parse', f'{args.base_ref}^{{commit}}'], cwd=ROOT, text=True).strip()
        migration = args.candidate.read_text()
        definitions = bench.reader_definitions(migration)
        if set(definitions) != {('function', name) for name in TARGETS}:
            raise ValueError('Migration must replace exactly the four approved existing functions')
        statements = migration_statements(migration)
        predecessor = bench.baseline(base, list(definitions))
        sql, case_count = build_real_sql(predecessor, statements)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    expected = bench.empty_guard_expected()
    app_prefix = ('set application_name=' + bench.literal('portal864-cv-' + args.visibility_nonce + '-initial-guard') + ';') if args.committed_visibility else ''
    initial = (visibility_run('portal864-cv-' + args.visibility_nonce + '-initial-guard', app_prefix + bench.guard_sql(), 60)
               if args.committed_visibility else bench.run(bench.guard_sql(), 60))
    if initial.returncode or initial.stdout.strip().splitlines() != expected:
        parser.error('Refusing unknown, nonempty, nonlocal or wrong-version target')
    catalog_prefix = ('set application_name=' + bench.literal('portal864-cv-' + args.visibility_nonce + '-initial-catalog') + ';') if args.committed_visibility else ''
    initial_catalog = (visibility_run('portal864-cv-' + args.visibility_nonce + '-initial-catalog', catalog_prefix + catalog_query() + ';', 60)
                       if args.committed_visibility else bench.run(catalog_query() + ';', 60))
    if initial_catalog.returncode:
        parser.error('Initial permanent metadata/manifest snapshot failed')
    if args.committed_visibility:
        return committed_visibility(args, context, inspected, owner, base, migration,
            statements, predecessor, json.loads(initial_catalog.stdout))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {'schemaVersion': 'portal.facets-navigation-upgrade.v1', 'passed': False,
        'classification': 'local rollback-only real source-writer/full-migration upgrade; not hosted latency',
        'baseCommit': base, 'candidateSha256': bench.sha(migration),
        'harnessSha256': bench.sha(Path(__file__).read_bytes()), 'sourceFixtureSha256': bench.sha(source_fixture()),
        'baselineReaderSha256': bench.sha(bench.definitions_sql(predecessor)),
        'containerId': inspected['Id'], 'dockerContext': context['Name'], 'ownerSha256': bench.sha(owner),
        'image': inspected['Config']['Image'], 'targetFunctions': list(TARGETS),
        'requestBudget': '8s', 'sessionWorkMem': '4MB', 'syntheticGuardVolume': None,
        'unresolvedProof': ['concurrent load', 'hosted production latency'], 'cleanup': None}
    try:
        records, digest = execute_case(sql, real_stem)
        if len(records) != 1:
            raise ValueError('Exactly one complete real-writer result required')
        real = records[0]
        by_phase = {phase: {r['label']: r for r in real['responses'] if r['phase'] == phase}
                    for phase in ('baseline', 'candidate')}
        if any(len(v) != case_count for v in by_phase.values()) or set(by_phase['baseline']) != set(by_phase['candidate']):
            raise ValueError('Missing/duplicate API response cases')
        if any((b['payload'], b['sqlstate']) != (by_phase['candidate'][label]['payload'], by_phase['candidate'][label]['sqlstate'])
               for label, b in by_phase['baseline'].items()):
            raise ValueError('Complete API JSON/SQLSTATE mismatch')
        before, after = (real['snapshots'][phase]['targetDefinitions'] for phase in ('baseline', 'candidate'))
        if set(before) != set(TARGETS) or set(after) != set(TARGETS) or any(before[name] == after[name] for name in TARGETS):
            raise ValueError('Every approved target must have exactly one changed definition')
        if set(real['checks']) != CHECK_LABELS or not real['sourceWriterTriggersEnabled'] or real['realSourceRows'] != {'processes': 4, 'flows': 2}:
            raise ValueError('Incomplete rollback guards or real source-writer fixture')
        report['realWriterUpgrade'] = real | {'sqlSha256': digest, 'completeResponseComparisons': case_count,
                                            'repeatApplication': True, 'fullMigrationStatements': len(statements)}
        if args.synthetic_processes:
            synthetic = build_synthetic_sql(predecessor, statements, args.synthetic_processes, args.synthetic_flows)
            records, digest = execute_case(synthetic, volume_stem)
            if len(records) != 2 or 'guardElapsedMs' not in records[0] or 'snapshot' not in records[1]:
                raise ValueError('Incomplete separately classified synthetic guard-volume result')
            report['syntheticGuardVolume'] = {'processVersions': 2 * args.synthetic_processes,
                'flowVersions': 2 * args.synthetic_flows, 'sqlSha256': digest,
                'summaryPaddingBytes': 3072,
                'guardElapsedMs': records[0]['guardElapsedMs'], 'result': records[1],
                'sourceWriterProof': False}
        report['passed'] = True
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        report['failure'] = str(exc)
    finally:
        cleanup = bench.run(bench.guard_sql(), 60)
        final_catalog = bench.run(catalog_query() + ';select private.portal_display_assert_contract_v1();', 60)
        report['cleanup'] = {'emptyRowsAndLocalIdentityVerified': cleanup.returncode == 0 and cleanup.stdout.strip().splitlines() == expected,
            'permanentMetadataAndManifestRestored': final_catalog.returncode == 0 and final_catalog.stdout.strip() == initial_catalog.stdout.strip(),
            'physicalPagesAndPlannerStatisticsMayRemain': True, 'resetBeforeOtherQualification': True}
        if not all(report['cleanup'][k] for k in ('emptyRowsAndLocalIdentityVerified', 'permanentMetadataAndManifestRestored')):
            report['passed'] = False
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'report': str(args.report), 'passed': report['passed'],
                      'comparisons': report.get('realWriterUpgrade', {}).get('completeResponseComparisons'),
                      'failure': report.get('failure'), 'cleanup': report['cleanup']}, indent=2))
    return int(not report['passed'])


if __name__ == '__main__':
    sys.exit(main())
