#!/usr/bin/env python3
"""Isolated synthetic fixture and rollback-only legacy Flow candidate comparison."""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / 'supabase/migrations/20261004025220_bound_flow_lexical_payloads.sql'
SIGNATURE = 'private.search_flows_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text[])'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--local-container', required=True,
               help='database774-perf-YYYYMMDD or supabase_db_database-engine-774[-suffix]; reset to pre-migration head first')
p.add_argument('--rows', type=int, default=134608)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if not re.fullmatch(r'(database774-perf-[0-9]{8}|supabase_db_database-engine-774(?:-[a-z0-9-]+)?)', a.local_container):
    p.error('An explicitly named isolated Database #774 local container is required; remote URLs are refused')
if not 10000 <= a.rows <= 200000:
    p.error('--rows must be between 10000 and 200000')
inspect = subprocess.run(['docker', 'inspect', '--format', '{{.Name}}', a.local_container],
                         capture_output=True, text=True, check=True).stdout.strip()
if inspect != '/' + a.local_container:
    raise SystemExit('Container identity mismatch')
cmd = ['docker', 'exec', '-i', a.local_container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
def sql(query):
    return subprocess.run(cmd, input=query, text=True, capture_output=True, check=True,
                          timeout=300).stdout
if sql('select exists(select 1 from public.flows limit 1);').strip() != 'f':
    raise SystemExit('A clean empty isolated baseline is required; this benchmark never truncates existing data')
base = sql(f"select pg_get_functiondef('{SIGNATURE}'::regprocedure)")
if 'paged_rows as materialized' in base:
    raise SystemExit('Reset the isolated project to migration 20261002154951 before running this upgrade benchmark')
# EXPLAIN the exact dynamic kernel with the same bound arguments as the RPC.
# No planner method or index is forced. jit/work_mem are identical for both arms.
def kernel(definition):
    body = definition.split('  v_sql := format($sql$', 1)[1].split('  $sql$,', 1)[0]
    return body.replace('%s', 'where f.search_text &@~| $14', 1).replace('%s', '', 1)
measure = """
create function pg_temp.measure_774(p_case text,p_query text,p_filter jsonb,p_page bigint,p_source text)
returns jsonb language plpgsql as $$
declare v_started timestamptz;v_ms numeric[]:=array[]::numeric[];v_rows jsonb;i integer;
begin
 for i in 1..5 loop
  v_started:=clock_timestamp();
  select coalesce(jsonb_agg(to_jsonb(r) order by r.rank,r.id),'[]') into v_rows
  from api.search_flows_latest(p_query,p_filter,'{}',10,p_page,p_source,'',null,null,array[p_query]) r;
  v_ms:=array_append(v_ms,round((extract(epoch from clock_timestamp()-v_started)*1000)::numeric,2));
 end loop;
 return jsonb_build_object('case',p_case,'ms',v_ms,'digest',md5(v_rows::text),'rows',jsonb_array_length(v_rows));
end $$;
"""
measure += """
create function pg_temp.measure_hybrid_774(p_case text,p_filter jsonb)
returns jsonb language plpgsql as $$
declare v_started timestamptz;v_ms numeric[]:=array[]::numeric[];v_rows jsonb;i integer;
 v_embedding text := '['||array_to_string(array_fill('0'::text,array[1024]),',')||']';
begin
 for i in 1..5 loop
  v_started:=clock_timestamp();
  select coalesce(jsonb_agg(to_jsonb(r)-'ordinality' order by r.ordinality),'[]') into v_rows
  from api.hybrid_search_flows('electricity',v_embedding,p_filter,0.5,20,0.5,0.5,10,'tg',10,1,array['electricity']) with ordinality r;
  v_ms:=array_append(v_ms,round((extract(epoch from clock_timestamp()-v_started)*1000)::numeric,2));
 end loop;
 return jsonb_build_object('case',p_case,'ms',v_ms,'digest',md5(v_rows::text),'rows',jsonb_array_length(v_rows));
end $$;
"""
cases = [
    ('broad_first', 'electricity', '{}', 1, 'tg'),
    ('broad_deep', 'electricity', '{}', 100, 'tg'),
    ('narrow', 'solar', '{}', 1, 'tg'),
    ('zero', 'absent774', '{}', 1, 'tg'),
    ('type', 'electricity', '{"flowType":"Product flow"}', 1, 'tg'),
    ('contributed', 'electricity', '{}', 1, 'co'),
]
def calls(phase):
    lexical = '\n'.join("select jsonb_build_object('phase','%s','record',pg_temp.measure_774('%s','%s','%s',%s,'%s'));" %
                     (phase, *case) for case in cases)
    return lexical + "\n" + "\n".join(
        "select jsonb_build_object('phase','%s','record',pg_temp.measure_hybrid_774('%s','%s'));" %
        (phase, name, filters) for name, filters in [('hybrid_broad', '{}'), ('hybrid_type', '{"flowType":"Product flow"}')])
setup = f"""begin;
set local search_path=public,extensions;
set local statement_timeout='120s';set local jit=off;set local work_mem='4MB';
alter table public.flows disable trigger user;
insert into public.flows(id,version,state_code,json,json_ordered,search_text,created_at,modified_at)
select md5((g/2)::text)::uuid,case when g%2=0 then '01.00.001' else '01.00.000' end,
 case when g%10=0 then 0 when g%10=1 then 200 else 100 end,
 jsonb_build_object('fixture',true,'label',case when g%2=0 then 'current' else 'previous' end,
 'flowDataSet',jsonb_build_object('modellingAndValidation',jsonb_build_object('LCIMethod',jsonb_build_object('typeOfDataSet',case when g%8=0 then 'Product flow' else 'Elementary flow' end))),
 'padding',(select string_agg(md5(g::text||':'||i::text),'') from generate_series(1,256) i)),
 '{{}}',array[case when g%19=0 then 'solar energy' else 'electricity power 电力' end],
 '2026-01-01'::timestamptz+g*interval '1 second','2026-01-01'::timestamptz+g*interval '1 second'
from generate_series(2,{a.rows + 1}) g;
commit;
vacuum (analyze) public.flows;
-- Create a conservative partially-visible heap by dirtying the final 16% of
-- the insertion range. Report actual visibility instead of assuming a ratio.
-- No semantic input or trigger changes between comparison arms.
update public.flows set modified_at=modified_at where created_at >= '2026-01-01'::timestamptz + {int(a.rows * 0.84)}*interval '1 second';
analyze public.flows;
select jsonb_build_object('fixture',jsonb_build_object('rows',count(*),'jsonBytes',round(avg(pg_column_size(json))),'relationBytes',pg_total_relation_size('public.flows'),'allVisiblePages',(select relallvisible from pg_class where oid='public.flows'::regclass),'heapPages',(select relpages from pg_class where oid='public.flows'::regclass)))
from public.flows;
"""
prepare = "prepare kernel_774(text,jsonb,bigint,bigint,text,uuid,uuid,integer,boolean,text,text[],boolean,jsonb,text[]) as "
explain = "explain(analyze,buffers,format json) execute kernel_774('electricity','{}',10,1,'tg',null,null,null,false,null,null,null,'[]',array['electricity']);"
# Read the after definition in an independent rollback-only transaction, avoiding
# source reconstruction of the candidate when creating the comparison kernel.
migration = re.sub(r'^begin;\s*|^commit;\s*', '', MIGRATION.read_text(), flags=re.M)
after = sql('begin;\n' + migration + f"\nselect pg_get_functiondef('{SIGNATURE}'::regprocedure);\nrollback;")
# The local-only fixture commits for VACUUM/visibility-map realism. The candidate
# migration and all comparison functions roll back; reset/release this environment
# afterward, including on a benchmark failure.
fixture_output = sql(setup)
query = ("begin;set local search_path=public,extensions;set local statement_timeout='120s';set local jit=off;set local work_mem='4MB';\n" + measure + calls('before') + '\n' + prepare + kernel(base) + ';\n' + explain +
         '\ndeallocate kernel_774;\n' + migration + '\n' + calls('after') + '\n' + prepare +
         kernel(after) + ';\n' + explain + '\nrollback;')
result = subprocess.run(cmd, input=query, text=True, capture_output=True, timeout=300)
result.stdout = fixture_output + result.stdout
# Preserve complete local synthetic evidence, including EXPLAIN; never expose raw
# hosted values. Failure still closes the connection and rolls the transaction back.
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.with_suffix('.raw.log').write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(f'Benchmark failed; inspect {a.output.with_suffix(".raw.log")}')
records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
fixture = records[0]['fixture']
measurements = records[1:]
if len(measurements) != 2 * (len(cases) + 2):
    raise SystemExit('Incomplete before/after measurements')
for before, after_record in zip(measurements[:len(cases) + 2], measurements[len(cases) + 2:]):
    if (before['record']['case'], before['record']['digest'], before['record']['rows']) != (
            after_record['record']['case'], after_record['record']['digest'], after_record['record']['rows']):
        raise SystemExit('Full-page identity/rank/payload/count drift')
# Multiline EXPLAIN arrays are the only array records in the stream.
plans = []
decoder = json.JSONDecoder()
for match in re.finditer(r'^\[\s*$', result.stdout, re.M):
    plans.append(decoder.raw_decode(result.stdout[match.start():])[0][0])
if len(plans) != 2:
    raise SystemExit('Expected both natural execution plans')
def nodes(plan):
    yield plan
    for child in plan.get('Plans', []):
        yield from nodes(child)
after_nodes = list(nodes(plans[1]['Plan']))
hydration = [n for n in after_nodes if n.get('Index Name') == 'flows_pkey' and n.get('Alias') == 'payload']
if len(hydration) != 1 or hydration[0]['Actual Loops'] > 10 or hydration[0]['Actual Rows'] != 1:
    raise SystemExit('Exact payload hydration exceeded page bound')
if plans[1]['Plan']['Temp Written Blocks'] >= plans[0]['Plan']['Temp Written Blocks']:
    raise SystemExit('Narrow kernel did not reduce temporary writes')
envelope = {'benchmark': 'flow-lexical-payloads.v1', 'profile': 'isolated-synthetic-partially-visible',
            'fixture': fixture, 'measurements': measurements, 'plans': plans}
a.output.write_text(json.dumps(envelope, indent=2) + '\n')
print(json.dumps({'benchmark': envelope['benchmark'], 'fixture': fixture,
                  'sameDigests': True, 'payloadHydrationLoops': hydration[0]['Actual Loops'],
                  'tempWrittenBlocks': [plan['Plan']['Temp Written Blocks'] for plan in plans],
                  'output': str(a.output)}))
