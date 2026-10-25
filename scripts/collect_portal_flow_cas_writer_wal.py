#!/usr/bin/env python3
"""Database #869: bounded, rollback-only real-writer navigation UPSERT WAL.

Only each actual source CAS update enables nested WAL logging. Existing real
writers/guards execute normally. Root WAL from distinct navigation UPSERT
invocations measures direct heap plus all index maintenance, not one index in
isolation. Profiling times are diagnostic; qualified source timing is separate.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT/'supabase/tests/upgrade/collect_portal_flow_cas_cutover.py'
SPEC = importlib.util.spec_from_file_location('portal_cas_nested_wal_helpers',HELPER)
assert SPEC and SPEC.loader
cost = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cost)
upgrade, bench = cost.upgrade, cost.bench
BASE = upgrade.CAS_BASE
SAMPLES = 3
OPERATIONS = ('cas_one','cas_batch')
SCHEMA = 'private'
RELATION = 'display_navigation_versions_v1'
REFERENCES = {
 'afterTriggers':'https://www.postgresql.org/docs/17/using-explain.html#USING-EXPLAIN-ANALYZE',
 'nestedWal':'https://www.postgresql.org/docs/17/auto-explain.html',
 'nodeWal':'https://github.com/postgres/postgres/blob/REL_17_11/src/backend/commands/explain.c#L2170-L2174',
 'nodeIntervals':'https://github.com/postgres/postgres/blob/REL_17_11/src/backend/executor/instrument.c#L60-L103'}


def operations() -> dict[str,tuple[str,int]]:
    single = cost.update_sql(cost.TARGET_ONE,'67-56-1')
    batch = ("update public.flows set json=jsonb_set(json,"+bench.literal(cost.CAS_PATH)+",'\"67-56-1\"'::jsonb) "
             "where version='01.00.000' and id in ('86900000-0000-4000-8000-000000000101',"
             "'86900000-0000-4000-8000-000000000102','86900000-0000-4000-8000-000000000109') returning id")
    return {'cas_one':(single,1),'cas_batch':(batch,3)}


def build_sql(predecessor: dict, phases) -> str:
    sql = """set application_name='portal864-serial';set search_path='';
begin;set local work_mem='4MB';set local statement_timeout='60s';set local auto_explain.log_min_duration=-1;
do $$begin if not pg_try_advisory_xact_lock(864,1) then raise exception 'Another owned fixture is active';end if;end$$;
"""
    sql += cost.canonical_guard(predecessor)
    sql += "do $$begin if (select count(*) from supabase_migrations.schema_migrations)<>439 then raise exception 'Exact 439 migration ledger required';end if;end$$;\n"
    sql += cost.writer_fixture()+upgrade.snapshot_helpers()
    sql += """
load 'auto_explain';
set local auto_explain.log_min_duration=-1;
set local auto_explain.log_analyze=on;
set local auto_explain.log_wal=on;
set local auto_explain.log_buffers=on;
set local auto_explain.log_timing=off;
set local auto_explain.log_triggers=off;
set local auto_explain.log_verbose=on;
set local auto_explain.log_format=json;
set local auto_explain.log_level=notice;
set local auto_explain.log_nested_statements=on;
set local auto_explain.log_parameter_max_length=0;
set local auto_explain.sample_rate=1;
create temp table sample_before(data jsonb,native jsonb);
"""
    for variant in ('baseline','candidate'):
        if variant == 'candidate':
            sql += '\n'.join(phases.prepare)+'\n'+'\n'.join(phases.activate)+'\n'+upgrade.native_assert_sql(True)
        for ordinal in range(-1,SAMPLES):
            for operation,(query,count) in operations().items():
                identity = json.dumps({'variant':variant,'label':operation+':'+str(ordinal)})
                # Snapshots precede the savepoint so their temporary row remains
                # available after rolling back only the actual source operation.
                sql += "truncate sample_before;insert into sample_before select pg_temp.upgrade_snapshot()->'data',pg_temp.upgrade_snapshot()#>'{nativeExtension,facts}';\nsavepoint source_operation;\n"
                sql += "do $$begin raise notice 'portal864_plan_begin:%',"+bench.literal(identity)+";end$$;\n"
                sql += "set local auto_explain.log_min_duration=0;\n"
                returning = "returning jsonb_build_object('record','source-row','variant',"+bench.literal(variant)+",'operation',"+bench.literal(operation)+",'ordinal',"+str(ordinal)+",'id',id)::text"
                if not query.endswith('returning id'):
                    raise ValueError('Exact source-update RETURNING boundary required')
                sql += query.removesuffix('returning id')+returning+";\n"
                sql += "set local auto_explain.log_min_duration=-1;\n"
                sql += "do $$begin raise notice 'portal864_plan_end:%',"+bench.literal(identity)+";end$$;\n"
                sql += """rollback to savepoint source_operation;
 do $$begin
 if current_setting('auto_explain.log_min_duration')<>'-1' then raise exception 'Nested WAL profiling leaked outside actual update';end if;
 if pg_temp.upgrade_snapshot()->'data' is distinct from (select data from sample_before)
 or pg_temp.upgrade_snapshot()#>'{nativeExtension,facts}' is distinct from (select native from sample_before) then
  raise exception 'Nested writer WAL sample rollback leaked logical data';
 end if;
 end$$;
release savepoint source_operation;
"""
    sql += upgrade.native_assert_sql(True)
    sql += """select jsonb_build_object('record','result','finalNativeIndexBytes',pg_relation_size('private.d807_portal_navigation_versions_flow_cas_v1_idx'));
rollback;
"""
    return sql


def navigation_invocations(group: dict) -> list[dict]:
    """Each logged event is one invocation; identical batch SQL is not deduped."""
    result=[]
    for event_number,event in enumerate(group['nestedPlans']):
        explain=event['explain'];root=explain.get('Plan',{});query=explain.get('Query Text','')
        if (root.get('Node Type'),root.get('Operation'),root.get('Schema'),root.get('Relation Name')) != ('ModifyTable','Insert',SCHEMA,RELATION):
            continue
        if not re.search(r'\bon\s+conflict\b',query,re.I) or root.get('Conflict Resolution')!='UPDATE':
            raise ValueError('Navigation INSERT must be the existing ON CONFLICT UPDATE writer')
        if any(type(root.get(key)) is not int or root[key]<0 for key in ('WAL Records','WAL FPI','WAL Bytes')):
            raise ValueError('Complete navigation root WAL counters required')
        # WAL counters are already accumulated, not per-loop averages. Read only
        # the root once; never sum its children or a wrapping function plan.
        result.append({'eventOrdinal':event_number,'querySha256':bench.sha(query),
                       'walRecords':root['WAL Records'],'walFpi':root['WAL FPI'],'walBytes':root['WAL Bytes'],
                       'conflictingTuples':root.get('Conflicting Tuples'),'tuplesInserted':root.get('Tuples Inserted'),
                       'rowsRemovedByConflictFilter':root.get('Rows Removed by Conflict Filter',0),
                       'actualLoops':root.get('Actual Loops'),'profiledDurationMs':event['durationMs']})
    return result


def parse_groups(log: Path, artifact: Path) -> list[dict]:
    summaries=[];current=None;group_bytes=0
    with bench.private_output(artifact) as output:
        output.write(b'{"groups":[')
        for kind,value,count in bench.iter_log_events(log):
            if kind=='begin':
                if current is not None: raise ValueError('Overlapping writer WAL groups')
                current=dict(value,nestedPlans=[]);group_bytes=0
            elif kind=='end':
                if current is None or any(value[key]!=current[key] for key in ('variant','label')):
                    raise ValueError('Writer WAL group boundary mismatch')
                invocations=navigation_invocations(current)
                if summaries: output.write(b',')
                output.write(json.dumps(current).encode())
                summaries.append({'variant':current['variant'],'label':current['label'],'eventCount':len(current['nestedPlans']),
                                  'nestedPlanBytes':group_bytes,'navigationInvocations':invocations})
                current=None
            else:
                if current is None: raise ValueError('Nested plan logged outside actual source-update window')
                group_bytes+=count
                if group_bytes>bench.MAX_GROUP_BYTES: raise ValueError('Writer WAL group exceeds bounded artifact limit')
                current['nestedPlans'].append(value)
        if current is not None: raise ValueError('Unclosed writer WAL group')
        output.write(b']}\n')
    return summaries


def summarize(groups: list[dict], measurements: list[dict]) -> dict:
    expected={(variant,operation,ordinal) for variant in ('baseline','candidate') for operation in OPERATIONS for ordinal in range(-1,SAMPLES)}
    indexed={}
    for group in groups:
        operation,ordinal=group['label'].rsplit(':',1);key=(group['variant'],operation,int(ordinal))
        if key in indexed: raise ValueError('Duplicate actual source-update WAL group')
        if operation not in operations(): raise ValueError('Unexpected writer operation')
        required=operations()[operation][1]
        invocations=group['navigationInvocations']
        if len(invocations)!=required or len({row['eventOrdinal'] for row in invocations})!=required:
            raise ValueError('Expected one navigation UPSERT invocation per actual source row')
        for row in invocations:
            if row['actualLoops']!=1 or row['conflictingTuples']!=1 or row['tuplesInserted']!=0 or row['rowsRemovedByConflictFilter']!=(1 if key[0]=='baseline' else 0):
                raise ValueError('Expected baseline no-op or candidate native-fact update not demonstrated')
        indexed[key]=group|{'operation':operation,'ordinal':int(ordinal),'expectedInvocations':required,
                          'walBytes':sum(row['walBytes'] for row in invocations),'walRecords':sum(row['walRecords'] for row in invocations),
                          'walFpi':sum(row['walFpi'] for row in invocations)}
    if set(indexed)!=expected: raise ValueError('Complete baseline/candidate warm-plus-three-sample matrix required')
    updates={}
    for row in measurements:
        if row.get('record')!='source-row': raise ValueError('Unexpected source-row proof record')
        key=(row['variant'],row['operation'],row['ordinal'])
        updates.setdefault(key,[]).append(row['id'])
    if set(updates)!=expected: raise ValueError('Actual source-update returned-row matrix incomplete')
    targets={'cas_one':{cost.TARGET_ONE},'cas_batch':{cost.TARGET_ONE,cost.TARGET_TWO,'86900000-0000-4000-8000-000000000109'}}
    for key,ids in updates.items():
        if len(ids)!=operations()[key[1]][1] or set(ids)!=targets[key[1]]:
            raise ValueError('Actual source update returned unexpected or duplicate ids')
    comparisons=[]
    for operation in OPERATIONS:
        b=[indexed['baseline',operation,n]['walBytes'] for n in range(SAMPLES)]
        c=[indexed['candidate',operation,n]['walBytes'] for n in range(SAMPLES)]
        if any(value<=0 for value in c): raise ValueError('Positive candidate native UPSERT WAL not observed')
        comparisons.append({'operation':operation,'sourceRows':operations()[operation][1],
                            'baselineWalBytes':b,'candidateWalBytes':c,'baselineMedianWalBytes':statistics.median(b),
                            'candidateMedianWalBytes':statistics.median(c),'incrementalMedianWalBytes':statistics.median(c)-statistics.median(b),
                            'incrementalMedianWalBytesPerSourceRow':(statistics.median(c)-statistics.median(b))/operations()[operation][1]})
    return {'samples':[indexed[key] for key in sorted(indexed)],'comparisons':comparisons,
            'warmupExcludedFromComparisons':True,'distinctNavigationInvocations':sum(len(g['navigationInvocations']) for g in groups)}


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',required=True,choices=[bench.CONTAINER])
    parser.add_argument('--base-ref',default=BASE,choices=[BASE])
    parser.add_argument('--owner-file',type=Path,default=bench.OWNER,choices=[bench.OWNER])
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    directory=args.report.with_suffix('.artifacts')
    if args.report.suffix!='.json' or not args.report.resolve().is_relative_to(bench.OWNER.parent.resolve()) or args.report.exists() or directory.exists():
        parser.error('New private owner-directory JSON report/artifact paths required')
    report={'schemaVersion':'portal.flow-cas-navigation-writer-wal.v1','passed':False,'baseCommit':BASE,'samplesPerOperation':SAMPLES,
            'walScope':'Direct navigation UPSERT root heap plus all index maintenance; not CAS-index-only bytes, trigger tree total, commit or rollback WAL',
            'timingScope':'Nested auto_explain profiling durations are diagnostic; qualified real-source timing is separate',
            'references':REFERENCES,'loggingWindow':'0ms only between begin/end markers surrounding each actual source CAS update; snapshots and A/B DDL remain disabled',
            'artifactLimits':{'logBytes':bench.MAX_LOG_BYTES,'stdoutBytes':bench.MAX_STDOUT_BYTES,'groupBytes':bench.MAX_GROUP_BYTES,'planBytes':bench.MAX_PLAN_BYTES},
            'cleanup':{'resetPerformed':False,'resetBeforeOtherQualification':True,'containersCreated':0,'volumesCreated':0}}
    admitted=False
    try:
        base=subprocess.check_output(['git','rev-parse',args.base_ref+'^{commit}'],cwd=ROOT,text=True).strip()
        _,source,phases=upgrade.load_candidate(base,None)
        predecessor=bench.baseline(base,list(bench.reader_definitions(source)))
        context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
        inspected=json.loads(subprocess.check_output(['docker','inspect',args.container],text=True))[0]
        owner=args.owner_file.read_text();bench.validate_target(context,inspected,owner)
        empty=bench.run(bench.guard_sql(),60)
        if empty.returncode or empty.stdout.strip().splitlines()!=bench.empty_guard_expected(): raise ValueError('Exact empty owned PG17.11 target required')
        initial_result=bench.run(cost.canonical_guard(predecessor)+upgrade.catalog_query()+';',60)
        if initial_result.returncode: raise ValueError('Canonical predecessor schema/body admission failed')
        initial=json.loads(initial_result.stdout);admitted=True
        directory.mkdir(mode=0o700)
        sql=build_sql(predecessor,phases)
        report.update(containerId=inspected['Id'],image=inspected['Config']['Image'],dockerContext=context['Name'],ownerSha256=bench.sha(owner),
                      postgresVersion='17.11',sessionWorkMem='4MB',administrativeStatementTimeout='60s',
                      resources={key:inspected['HostConfig'].get(key) for key in ('NanoCpus','CpuQuota','CpuPeriod','CpusetCpus','Memory','MemorySwap')},
                      collectorSha256=bench.file_sha(Path(__file__)),costHelpersSha256=bench.file_sha(HELPER),upgradeHelpersSha256=bench.file_sha(Path(upgrade.__file__)),
                      benchmarkSha256=bench.file_sha(Path(bench.__file__)),fixtureSha256=bench.sha(cost.writer_fixture()),bundleSha256=bench.sha(source),sqlSha256=bench.sha(sql),
                      initialMetadata=initial,phaseTransactions='A/B actual inner statements in one outer rollback-only transaction; no ledger transition or phase commit claim')
        with bench.private_output(directory/'collector.py') as handle:handle.write(Path(__file__).read_bytes())
        with bench.private_output(directory/'profile.sql') as handle:handle.write(sql.encode())
        completed=bench.run_logged(directory/'profile.sql',directory/'stdout.jsonl',directory/'nested.log',300)
        report['artifactActualBytes']={name:(directory/name).stat().st_size for name in ('nested.log','stdout.jsonl')}
        if completed.returncode: raise RuntimeError('Nested WAL execution failed; inspect bounded private log')
        rows=[json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
        results=[row for row in rows if row.get('record')=='result']
        returned=[row for row in rows if row.get('record')=='source-row']
        if len(results)!=1 or len(results)+len(returned)!=len(rows): raise ValueError('One result plus complete actual source-row proof required')
        groups=parse_groups(directory/'nested.log',directory/'nested-plans.json')
        report['navigationWal']=summarize(groups,returned)
        report['sourceRows']=returned
        report['finalNativeIndexBytes']=results[0]['finalNativeIndexBytes']
        report['nestedPlanArtifactSha256']=bench.file_sha(directory/'nested-plans.json')
        report['passed']=True
    except Exception as exc:
        report['failure']=type(exc).__name__+': '+str(exc)
    finally:
        if admitted:
            try:
                final=bench.run(upgrade.catalog_query()+';'+bench.guard_sql()+"select pg_try_advisory_xact_lock(864,1);",60)
                lines=final.stdout.strip().splitlines()
                if final.returncode or not lines or json.loads(lines[0])!=initial or lines[1:]!=bench.empty_guard_expected()+['t']:
                    raise ValueError('Logical/schema rollback, empty owned tables, released connection or advisory-lock proof failed')
                report['cleanup'].update(logicalDataAndSchemaRolledBack=True,emptyOwnedTables=True,manifestAndMetadataRestored=True,activeFixtureSessions=0,fixtureLockReleased=True,
                                         disposition='No retained logical/native schema changes; physical pages/statistics may remain, Main owns exact reset')
            except Exception as exc:
                report['passed']=False;report['cleanup']['failure']=type(exc).__name__+': '+str(exc)
        args.report.parent.mkdir(parents=True,exist_ok=True)
        with bench.private_output(args.report) as handle:handle.write((json.dumps(report,indent=2)+'\n').encode())
    print(json.dumps({'report':str(args.report),'passed':report['passed'],'failure':report.get('failure'),'artifactActualBytes':report.get('artifactActualBytes'),'cleanup':report['cleanup']},indent=2))
    return int(not report['passed'])


if __name__=='__main__':raise SystemExit(main())
