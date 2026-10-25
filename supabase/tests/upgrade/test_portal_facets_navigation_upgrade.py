#!/usr/bin/env python3
"""Database #864: guarded, rollback-only full-migration upgrade qualification.

The exact task-owned local PG17.11 container is the only accepted target. Real
source INSERTs and unchanged source/settings/projection hashes qualify upgrade
correctness. Optional direct-projection volume timing is separately classified
and never substitutes for the real writer fixture. No hosted DSN is accepted.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

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


def rejection(label: str, setup: str, statements: list[str], state: str, message: str) -> str:
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
 insert into upgrade_checks values({bench.literal(label)},jsonb_build_object('sqlstate',caught_state,'message',caught_message,'migrationRolledBack',true,'fixtureRolledBack',true));
end$rejection$;
"""


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
    guard = [s for s in statements if '$display_facets_cutover_guard$' in s]
    if len(guard) != 1:
        raise ValueError('Exactly one named cutover guard required for separate volume timing')
    sql = bench.fixture(processes, flows, 1024) + bench.definitions_sql(predecessor) + snapshot_helpers()
    sql += "insert into upgrade_snapshots values('baseline',pg_temp.upgrade_snapshot());set local statement_timeout='60s';create temp table guard_timing(started timestamptz);insert into guard_timing values(clock_timestamp());\n"
    sql += guard[0] + "\nselect jsonb_build_object('guardElapsedMs',extract(epoch from clock_timestamp()-started)*1000) from guard_timing;\n"
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True, choices=[bench.CONTAINER])
    parser.add_argument('--base-ref', required=True)
    parser.add_argument('--candidate', type=Path, default=CANDIDATE, choices=[CANDIDATE])
    parser.add_argument('--owner-file', type=Path, default=bench.OWNER, choices=[bench.OWNER])
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--synthetic-processes', type=int, default=0)
    parser.add_argument('--synthetic-flows', type=int, default=0)
    args = parser.parse_args()
    if not args.report.resolve().is_relative_to(bench.OWNER.parent.resolve()):
        parser.error('Evidence must stay in the task-owned private scratch directory')
    real_stem = args.report.with_name(args.report.stem + '-real')
    volume_stem = args.report.with_name(args.report.stem + '-synthetic')
    paths = [args.report] + [s.with_suffix(ext) for s in (real_stem, volume_stem) for ext in ('.sql', '.log')]
    if len(set(paths)) != len(paths) or any(p.exists() for p in paths):
        parser.error('Report and SQL/log evidence paths must all be new')
    if not ((args.synthetic_processes == args.synthetic_flows == 0) or
            (20 <= args.synthetic_processes <= 20000 and 40 <= args.synthetic_flows <= 100000)):
        parser.error('Synthetic counts must both be omitted, or Process20..20000 and Flow40..100000')
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
    initial = bench.run(bench.guard_sql(), 60)
    if initial.returncode or initial.stdout.strip().splitlines() != expected:
        parser.error('Refusing unknown, nonempty, nonlocal or wrong-version target')
    initial_catalog = bench.run(catalog_query() + ';', 60)
    if initial_catalog.returncode:
        parser.error('Initial permanent metadata/manifest snapshot failed')
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
        if len(real['checks']) != 6 or not real['sourceWriterTriggersEnabled'] or real['realSourceRows'] != {'processes': 4, 'flows': 2}:
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
