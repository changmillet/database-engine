#!/usr/bin/env python3
"""Rollback-only, synthetic Database #793 index qualification; never a hosted probe."""
import argparse
import json
import subprocess
from pathlib import Path


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local-container', required=True)
    parser.add_argument('--roots', type=int, default=250000)
    parser.add_argument('--factors', type=int, default=20000,
                        help='Unique nested factor objects per document, across 25 documents')
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.local_container != 'supabase_db_database-engine-793':
        parser.error('Only exact task-owned supabase_db_database-engine-793 is allowed; URLs are refused')
    if not 100000 <= args.roots <= 1000000:
        parser.error('--roots must be between 100000 and 1000000')
    if not 10000 <= args.factors <= 100000 or not 3 <= args.repeats <= 9:
        parser.error('--factors must be 10000..100000 and --repeats 3..9')
    identity = subprocess.run(['docker', 'inspect', '--format', '{{.Name}}', args.local_container],
                              check=True, capture_output=True, text=True).stdout.strip()
    if identity != '/' + args.local_container:
        raise SystemExit('Docker container identity mismatch')
    command = ['docker', 'exec', '-i', args.local_container, 'psql', '-X', '-qAt',
               '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']

    def sql(query):
        return subprocess.run(command, input=query, text=True, capture_output=True,
                              check=True, timeout=900).stdout.strip()

    if sql("select to_regnamespace('issue793_benchmark') is null;") != 't':
        raise SystemExit('Fixture schema already exists; refuse to reuse or delete it')
    source = sql("select jsonb_build_object('postgres',version(),'pgroonga',"
                 "(select extversion from pg_extension where extname='pgroonga'),"
                 "'head',(select max(version) from supabase_migrations.schema_migrations));")
    # These are ordinary logged relations, not TEMP/UNLOGGED extension-index fixtures.
    setup = f"""begin;
set local statement_timeout='180s';
set local lock_timeout='5s';
set local jit=off;
set local work_mem='4MB';
do $$begin
 if to_regnamespace('issue793_benchmark') is not null then
  raise exception 'fixture collision';
 end if;
end$$;
create schema issue793_benchmark;
create table issue793_benchmark.issues(id uuid primary key,check_id uuid not null);
create index on issue793_benchmark.issues(check_id,id);
create table issue793_benchmark.roots(
 closure_issue_id uuid references issue793_benchmark.issues(id) on delete cascade,
 root_dataset_type text not null,root_dataset_id uuid not null,
 root_dataset_version text not null,impact_role text not null,witness_path jsonb not null,
 primary key(closure_issue_id,root_dataset_type,root_dataset_id,root_dataset_version,impact_role));
create index roots_duplicate on issue793_benchmark.roots
 (closure_issue_id,root_dataset_type,root_dataset_id,root_dataset_version);
insert into issue793_benchmark.issues
select md5('issue793:'||g)::uuid,md5('check793:'||(g/100))::uuid
from generate_series(0,{args.roots // 25 + 1}) g;
insert into issue793_benchmark.issues values(md5('copy793')::uuid,md5('copycheck793')::uuid);
insert into issue793_benchmark.roots
select md5('issue793:'||(g/25))::uuid,'process',md5('root793:'||(g/2))::uuid,
 '01.00.000',case when g%2=0 then 'root' else 'support' end,'[]'::jsonb
from generate_series(0,{args.roots - 1}) g;
create table issue793_benchmark.methods(id integer primary key,version text not null,json jsonb not null);
insert into issue793_benchmark.methods
select m,'01.00.000',jsonb_build_object('method',jsonb_build_object('id',m,'group',m%5),
 'LCIAMethodDataSet',jsonb_build_object('factors',(
  select jsonb_agg(jsonb_build_object('reference',md5(m::text||':'||f),
   'factor',f,'category',f%31,'tag',md5('factor793:'||m||':'||f),
   'amount',(f::numeric/100003))) from generate_series(1,{args.factors}) f)))
from generate_series(1,25) m;
create index methods_json_gin on issue793_benchmark.methods using gin(json);
alter table issue793_benchmark.methods enable row level security;
create policy read_methods on issue793_benchmark.methods for select to authenticated using(true);
grant usage on schema issue793_benchmark to authenticated;
grant select on issue793_benchmark.methods to authenticated;
analyze issue793_benchmark.issues;
analyze issue793_benchmark.roots;
analyze issue793_benchmark.methods;
select jsonb_build_object('type','fixture','roots',{args.roots},'methods',count(*),
 'factorsPerMethod',{args.factors},'jsonTextBytes',sum(octet_length(json::text)),
 'storedJsonBytes',sum(pg_column_size(json)),
 'methodsTotalBytes',pg_total_relation_size('issue793_benchmark.methods'),
 'methodGINBytes',pg_relation_size('issue793_benchmark.methods_json_gin'),
 'rootsPKBytes',pg_relation_size('issue793_benchmark.roots_pkey'),
 'rootsDuplicateBytes',pg_relation_size('issue793_benchmark.roots_duplicate'))
from issue793_benchmark.methods;
create function pg_temp.measure793(p_case text,p_query text,p_write boolean,p_phase text)
returns jsonb language plpgsql as $$
declare v_plan jsonb;v_result jsonb;v_first text;v_ms numeric[]:='{{}}';
 v_started timestamptz;v_lsn pg_lsn;v_wal bigint[]:='{{}}';v_count bigint;i integer;
begin
 if p_write then
  for i in 1..{args.repeats} loop
   v_started:=clock_timestamp();v_lsn:=pg_current_wal_insert_lsn();
   begin
    execute 'explain(analyze,buffers,wal,format json) '||p_query into v_plan;
    raise exception using errcode='ZX793',message='rollback benchmark write';
   exception when sqlstate 'ZX793' then null;
   end;
   v_ms:=array_append(v_ms,extract(epoch from clock_timestamp()-v_started)*1000);
   v_wal:=array_append(v_wal,pg_wal_lsn_diff(pg_current_wal_insert_lsn(),v_lsn)::bigint);
  end loop;
 else
  for i in 1..{args.repeats} loop
   v_started:=clock_timestamp();
   execute 'select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from ('||p_query||') r'
    into v_result;
   v_ms:=array_append(v_ms,extract(epoch from clock_timestamp()-v_started)*1000);
   if v_first is null then v_first:=md5(v_result::text);
   elsif v_first<>md5(v_result::text) then raise exception 'nondeterministic fixture query';end if;
  end loop;
  execute 'explain(analyze,buffers,format json) '||p_query into v_plan;
 end if;
 return jsonb_build_object('type','measurement','phase',p_phase,'case',p_case,
  'write',p_write,'ms',v_ms,'walBytes',v_wal,'digest',v_first,
  'resultRows',case when not p_write then jsonb_array_length(v_result) end,'plan',v_plan);
end$$;
grant execute on function pg_temp.measure793(text,text,boolean,text) to authenticated;
"""
    issue = "md5('issue793:123')::uuid"
    roots = [
        ('issue_lookup', f'select * from issue793_benchmark.roots where closure_issue_id={issue} '
         'order by root_dataset_type,root_dataset_id,root_dataset_version,impact_role', False),
        ('four_key_lookup', f"select * from issue793_benchmark.roots where closure_issue_id={issue} "
         "and root_dataset_type='process' and root_dataset_id=md5('root793:1540')::uuid "
         "and root_dataset_version='01.00.000' order by impact_role", False),
        ('gc_prefix_count', "select count(*) as roots from issue793_benchmark.roots r join "
         "issue793_benchmark.issues i on i.id=r.closure_issue_id where i.check_id=md5('check793:1')::uuid", False),
        ('reused_scan_copy', "insert into issue793_benchmark.roots select md5('copy793')::uuid,"
         f'root_dataset_type,root_dataset_id,root_dataset_version,impact_role,witness_path '
         f'from issue793_benchmark.roots where closure_issue_id={issue}', True),
        ('bounded_gc_delete', 'with doomed as (select r.ctid from issue793_benchmark.roots r '
         "join issue793_benchmark.issues i on i.id=r.closure_issue_id "
         "where i.check_id=md5('check793:1')::uuid limit 500) delete from "
         'issue793_benchmark.roots r using doomed where r.ctid=doomed.ctid', True),
        ('cascade_delete', f'delete from issue793_benchmark.issues where id={issue}', True),
    ]
    # Keep optional smaller profiles' needle inside their actual nested array.
    needle = min(17123, args.factors)
    methods = [
        ('method_id_detail', 'select id,md5(json::text) as payload from issue793_benchmark.methods '
         'where id=13 order by id', False),
        ('method_scalar_one', 'select id from issue793_benchmark.methods where '
         "json @> '{\"method\":{\"id\":13}}' order by id", False),
        ('method_scalar_some', 'select id from issue793_benchmark.methods where '
         "json @> '{\"method\":{\"group\":3}}' order by id", False),
        ('method_nested_one', 'select id from issue793_benchmark.methods where '
         "json @> jsonb_build_object('LCIAMethodDataSet',jsonb_build_object('factors',"
         f"jsonb_build_array(jsonb_build_object('reference',md5('13:{needle}'))))) order by id", False),
        ('method_nested_zero', 'select id from issue793_benchmark.methods where '
         "json @> '{\"LCIAMethodDataSet\":{\"factors\":[{\"reference\":\"absent793\"}]}}' order by id", False),
        ('method_nested_all', 'select id from issue793_benchmark.methods where '
         "json @> '{\"LCIAMethodDataSet\":{\"factors\":[{\"category\":7}]}}' order by id", False),
        ('method_filtered_payload', 'select id,md5(json::text) as payload from issue793_benchmark.methods '
         "where json @> '{\"method\":{\"group\":3}}' order by id", False),
        ('method_structural_all', 'select id from issue793_benchmark.methods where '
         "json @> '{\"LCIAMethodDataSet\":{\"factors\":[]}}' order by id", False),
        ('method_key_exists', "select id from issue793_benchmark.methods where json ? 'method' order by id", False),
        ('method_large_write', "update issue793_benchmark.methods set json=jsonb_set(json,"
         f"'{{LCIAMethodDataSet,factors,{needle-1},tag}}',to_jsonb('replacement793'::text)) where id=13", True),
    ]

    def calls(cases, phase):
        return '\n'.join(f'select pg_temp.measure793({literal(name)},{literal(query)},'
                         f'{str(write).lower()},{literal(phase)});' for name, query, write in cases)

    # Reads use authenticated SELECT under RLS. Writes remain operator-only on synthetic fixtures.
    def method_calls(phase):
        return ('set local role authenticated;\n' + calls([c for c in methods if not c[2]], phase)
                + '\nreset role;\n' + calls([c for c in methods if c[2]], phase))

    query = (setup + calls(roots, 'roots_both') + '\ndrop index issue793_benchmark.roots_duplicate;\n'
             + calls(roots, 'roots_pk_only') + '\n' + method_calls('methods_gin')
             + '\ndrop index issue793_benchmark.methods_json_gin;\n' + method_calls('methods_no_gin')
             + '\nrollback;\n')
    result = subprocess.run(command, input=query, text=True, capture_output=True, timeout=900)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix('.raw.log').write_text(result.stdout + result.stderr)
    cleanup = sql("select to_regnamespace('issue793_benchmark') is null;") == 't'
    if result.returncode or not cleanup:
        raise SystemExit(f'Benchmark failed; rollbackVerified={cleanup}; see {args.output.with_suffix(".raw.log")}')
    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    measurements = [r for r in records if r['type'] == 'measurement']
    expected = 2 * (len(roots) + len(methods))
    if len(measurements) != expected:
        raise SystemExit(f'Incomplete measurement receipt: {len(measurements)}/{expected}')
    for phase in ('methods_gin', 'methods_no_gin'):
        one = next(r for r in measurements if r['phase'] == phase and r['case'] == 'method_nested_one')
        zero = next(r for r in measurements if r['phase'] == phase and r['case'] == 'method_nested_zero')
        if one['resultRows'] != 1 or zero['resultRows'] != 0:
            raise SystemExit('Nested selective/zero fixture did not have the required cardinality')
    for cases, before, after in ((roots, 'roots_both', 'roots_pk_only'),
                                 (methods, 'methods_gin', 'methods_no_gin')):
        for name, _, write in cases:
            pair = [next(r for r in measurements if r['phase'] == phase and r['case'] == name)
                    for phase in (before, after)]
            if not write and pair[0]['digest'] != pair[1]['digest']:
                raise SystemExit(f'Result drift in {name}')
    def nodes(plan):
        yield plan
        for child in plan.get('Plans', []):
            yield from nodes(child)
    selective = [r for r in measurements if r['phase'] == 'roots_pk_only'
                 and r['case'] in ('issue_lookup', 'four_key_lookup')]
    if any(not any(n.get('Index Name') == 'roots_pkey' for n in nodes(r['plan'][0]['Plan']))
           for r in selective):
        raise SystemExit('Natural selective PK-prefix lookup was not proven')
    envelope = {'benchmark': 'search-index-retirement.793.v1', 'profile': 'synthetic-warm-local',
                'source': json.loads(source), 'fixture': records[0], 'measurements': measurements,
                'sameReadDigests': True, 'naturalPKPrefixProven': True,
                'cleanup': {'schema': 'issue793_benchmark', 'rollbackVerified': cleanup,
                            'retainedFixtures': [], 'retainedContainer': args.local_container},
                'limits': ['Synthetic warm evidence; no hosted p95 claim.',
                           'LCIA factors preserve large nested unique terms, not actual production distribution.',
                           'Payload digest forces JSON serialization but excludes network transport.',
                           'WAL LSN deltas are cluster-wide and can include background writes; plans also report statement WAL.',
                           'Synthetic roots mirror PK/FK; actual domain GC/lease/reuse suites remain required.',
                           'No fixture PGroonga index is created; ordinary logged tables only.']}
    args.output.write_text(json.dumps(envelope, indent=2) + '\n')
    print(json.dumps({'output': str(args.output), 'sameReadDigests': True,
                      'naturalPKPrefixProven': True, 'rollbackVerified': cleanup,
                      'fixture': records[0]}))


if __name__ == '__main__':
    main()
