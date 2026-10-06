#!/usr/bin/env python3
"""Rollback-only #785 invoker-path comparison on the explicitly reused campaign stack.

Uses the real Alias v2 executor and existing reviewed fixture. SQL scalar helpers
retain their inlining; this profile also records natural verbose plans proving
the Navigation matcher was already a function call before adding its SET clause.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = 'supabase_db_database-engine-777-pg1711'
TARGETS = (
    'private.dataset_alias_v2_deny(text,integer,text,jsonb)',
    'private.dataset_alias_v2_derivative_chunks(uuid,text,jsonb)',
    'private.dataset_alias_v2_derivative_target_ok(jsonb)',
    'private.dataset_alias_v2_exchange_keys_ok(jsonb)',
    'private.dataset_alias_v2_multiply_amount(text,text)',
    'private.dataset_alias_v2_plan_keys_ok(jsonb)',
    'private.dataset_alias_v2_replace_exchange_amounts(jsonb,jsonb)',
    'private.dataset_alias_v2_replace_flow_reference(jsonb,jsonb)',
    'private.dataset_alias_v2_replace_fu_text(jsonb,jsonb)',
    'private.dataset_length_time_v1_multiply_amount(text)',
    'private.dataset_length_time_v1_plan_keys_ok(jsonb)',
    'private.dataset_length_time_v1_replace_exchange_amounts(jsonb,jsonb)',
    'private.portal_navigation_version_matches_v3(text,jsonb,uuid,text)',
)


def run(sql: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'psql', '-h', '/var/run/postgresql',
         '-U', 'postgres', '-d', 'postgres', '-Atq', '-v', 'ON_ERROR_STOP=1'],
        input=sql, text=True, capture_output=True, timeout=1200,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True, choices=(CONTAINER,))
    parser.add_argument('--reuse-campaign', required=True, choices=('workspace-1701',))
    parser.add_argument('--actions', type=int, default=50)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    if not (2 <= args.actions <= 4096 and 2 <= args.samples <= 20):
        parser.error('Require 2..4096 actions and 2..20 balanced samples')
    paths = [args.report, args.report.with_suffix('.sql'), args.report.with_suffix('.log')]
    if any(p.exists() for p in paths):
        parser.error('Evidence paths must all be new')
    context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):
        parser.error('Only local Unix Docker is admitted')
    guard = "select inet_server_addr() is null; select current_setting('server_version'); " + '; '.join(
        f'select count(*) from {table}' for table in (
            'public.processes', 'public.flows', 'public.unitgroups', 'public.flowproperties',
            'private.portal_navigation_versions_v1', 'private.portal_catalog_facet_rows_v1')) + ';'
    expected = ['t', '17.11'] + ['0'] * 6
    before = run(guard)
    if before.returncode or before.stdout.strip().splitlines() != expected:
        parser.error('Refusing unknown, non-local, wrong-version or populated target')
    fixture_path = ROOT / 'supabase/tests/20260921_foundry60_time_alias_v2_batch.sql'
    fixture = fixture_path.read_text().split('-- =================================================================')[0]
    fixture = fixture.replace('select plan(119);', '')
    if fixture.count('\nbegin;') != 1 or '\ncommit;' in fixture or '\nrollback;' in fixture:
        raise ValueError('Expected the single-transaction reviewed Alias fixture prefix')
    sql = fixture.replace('begin;', 'begin;\ngrant portal_public_executor to postgres with inherit true, set true;', 1)
    sql += f"""
create temp table issue785_clone_ids as
select ('78500000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid id from generate_series(1,{args.actions - 2}) i;
insert into public.processes(id,version,user_id,state_code,json_ordered,modified_at)
select c.id,'01.00.000',f.actor,0,pg_temp.v2_process(c.id,'01.00.000',f.flow_id,'01.00.000','Alias flow')::json,'2026-09-21'
from issue785_clone_ids c cross join v2_fixture f;
create temp table issue785_batch_input as
with base as(select pg_temp.v2_batch() b), extras as (
 select coalesce(jsonb_agg(pg_temp.v2_resign(
  jsonb_set(jsonb_set((b->'actions'->1)||jsonb_build_object('id',c.id,'action_id',c.id::text),
    '{{expected_json_ordered,processDataSet,processInformation,dataSetInformation,common:UUID}}',to_jsonb(c.id)),
    '{{desired_json_ordered,processDataSet,processInformation,dataSetInformation,common:UUID}}',to_jsonb(c.id)))), '[]') actions,
 coalesce(jsonb_agg((b->'text_actions'->0)||jsonb_build_object('id',c.id)), '[]') texts
 from base cross join issue785_clone_ids c)
select pg_temp.v2_batch(jsonb_build_object('processes',actions,'text_actions',texts)) b from extras;
create temp table issue785_samples(variant text,label text,ordinal integer,elapsed_ms numeric,payload jsonb);
create temp table issue785_plans(variant text,label text,payload jsonb);
create temp table issue785_scalars as select i,i::text amount,to_jsonb(i::text) val from generate_series(1,20000) i;
grant select on issue785_scalars to portal_public_executor;
create function pg_temp.issue785_batch() returns jsonb language plpgsql as $$
declare p jsonb; s jsonb;
begin
 begin
  p:=pg_temp.v2_call((select b from issue785_batch_input));
  if p->>'ok' is distinct from 'true' then raise exception 'Alias batch did not apply'; end if;
  s:=jsonb_build_object('ok',p->'ok','code',p->'code','counts',p->'counts',
   'contentDigest',(select md5(string_agg(id::text||json_ordered::text,',' order by id)) from public.processes
     where id in(select id from issue785_clone_ids) or id=(select process_id from v2_fixture)));
  raise exception using errcode='P7850',message='rollback benchmark application';
 exception when sqlstate 'P7850' then null; end;
 return s;
end $$;
create function pg_temp.issue785_measure(v text,l text,i integer,s text) returns void language plpgsql as $$
declare t timestamptz:=clock_timestamp(); p jsonb;
begin execute s into p; insert into issue785_samples values(v,l,i,extract(epoch from clock_timestamp()-t)*1000,p);end $$;
create function pg_temp.issue785_plan(v text,l text,s text) returns void language plpgsql as $$
declare p jsonb;
begin execute 'explain(verbose,format json) '||s into p; insert into issue785_plans values(v,l,p);end $$;
"""
    cases = {
        'scalar': "select to_jsonb(sum(case when private.dataset_length_time_v1_scalar_ok(val,'^[0-9]+$') then 1 else 0 end)) from issue785_scalars",
        'amount': "select to_jsonb(md5(string_agg(private.dataset_alias_v2_multiply_amount(amount,private.dataset_alias_v2_factor()::text),',' order by i))) from issue785_scalars",
        'batch': 'select pg_temp.issue785_batch()',
    }
    for ordinal in range(-1, args.samples):
        for variant in (('baseline', 'candidate') if ordinal % 2 == 0 else ('candidate', 'baseline')):
            sql += '\n' + '\n'.join(f'alter function {f} ' +
                ("set search_path=''" if variant == 'candidate' else 'reset search_path') + ';' for f in TARGETS) + '\n'
            for label, statement in cases.items():
                quoted = statement.replace("'", "''")
                sql += f"select pg_temp.issue785_measure('{variant}','{label}',{ordinal},'{quoted}');\n"
            if ordinal == -1:
                for label, statement in {
                    'scalarInlining': "select private.dataset_length_time_v1_scalar_ok(val,'^[0-9]+$') from issue785_scalars",
                    'navigationMatcher': "select private.portal_navigation_version_matches_v3('process','{\"geographyNodeId\":\"geo:cn\"}',('78500000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.000') from issue785_scalars",
                    'derivativeChunks': "select private.dataset_alias_v2_derivative_chunks(('78500000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,amount,to_jsonb(array[i])) from issue785_scalars",
                    'derivativeTarget': 'select private.dataset_alias_v2_derivative_target_ok(val) from issue785_scalars',
                    'exchangeKeys': 'select private.dataset_alias_v2_exchange_keys_ok(val) from issue785_scalars',
                    'aliasPlanKeys': 'select private.dataset_alias_v2_plan_keys_ok(val) from issue785_scalars',
                    'lengthPlanKeys': 'select private.dataset_length_time_v1_plan_keys_ok(val) from issue785_scalars',
                }.items():
                    quoted = statement.replace("'", "''")
                    sql += f"select pg_temp.issue785_plan('{variant}','{label}','{quoted}');\n"
    sql += """
select jsonb_build_object(
 'samples',(select jsonb_agg(to_jsonb(s)-'payload') from issue785_samples s where ordinal>=0),
 'equivalence',(select jsonb_agg(jsonb_build_object('label',b.label,'ordinal',b.ordinal,'equal',b.payload=c.payload))
   from issue785_samples b join issue785_samples c using(label,ordinal) where b.variant='baseline' and c.variant='candidate'),
 'plans',(select jsonb_agg(to_jsonb(p)) from issue785_plans p));
rollback;
"""
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.with_suffix('.sql').write_text(sql)
    try:
        result = run(sql)
        args.report.with_suffix('.log').write_text(result.stdout + '\n' + result.stderr)
    finally:
        cleanup = run(guard)
        if cleanup.returncode or cleanup.stdout.strip().splitlines() != expected:
            raise RuntimeError('Rollback fixture/version guard failed')
    if result.returncode:
        print(f'Benchmark failed; see {args.report.with_suffix(".log")}')
        return result.returncode
    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    report = records[-1] if records else None
    if not isinstance(report, dict) or not all(k in report for k in ('samples', 'equivalence', 'plans')):
        raise RuntimeError('Missing benchmark evidence')
    report.update({'actions': args.actions, 'samplesPerVariant': args.samples,
        'targets': TARGETS, 'fixtureSha256': hashlib.sha256(fixture_path.read_bytes()).hexdigest(),
        'sqlSha256': hashlib.sha256(sql.encode()).hexdigest(), 'container': CONTAINER,
        'scope': 'local17.11 synthetic real Alias executor; no hosted or physical-upgrade qualification', 'cleanupRows': 0})
    report['medians'] = {label: {variant: statistics.median(
        s['elapsed_ms'] for s in report['samples'] if s['variant'] == variant and s['label'] == label)
        for variant in ('baseline', 'candidate')} for label in cases}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    failures = [x for x in report['equivalence'] if x['equal'] is not True]
    print(json.dumps({'report': str(args.report), 'medians': report['medians'], 'failures': failures, 'cleanupRows': 0}, indent=2))
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
