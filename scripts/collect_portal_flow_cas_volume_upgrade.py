#!/usr/bin/env python3
"""Database #869: fixed owned-local committed CAS-dense A/B upgrade evidence.

This is synthetic projection volume/lock evidence, not real-writer, hosted p95
or concurrent-load qualification. Actual migration text/order is preserved;
timestamp/held-lock observations add small measured instrumentation overhead.
No artificial holds, migration-ledger writes, remote targets or cleanup resets.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
import benchmark_portal_facets_navigation as bench

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('portal_cas_volume_upgrade_helpers', ROOT/'supabase/tests/upgrade/test_portal_facets_navigation_upgrade.py')
assert SPEC and SPEC.loader
upgrade = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upgrade)
BASE = '6a880838efbf4d453103a1141e9282db130171e8'
PREPARE = ROOT/'supabase/migrations/20261025103759_prepare_portal_flow_cas_fact.sql'
ACTIVATE = ROOT/'supabase/migrations/20261025103800_activate_portal_flow_cas_fact.sql'
PROCESS_DATASETS, FLOW_DATASETS, PADDING = 10000, 69000, 3072
SCOPES = ('tiangong_lca','bafu,tiangong_lca,uslci,worldsteel')
RELATIONS = ('private.display_catalog_search_rows_v1','private.display_catalog_search_rows_v2','private.display_navigation_versions_v1')
APPLICATION = 'portal864-serial'  # Exact existing guard/cancellation ownership.


def relation_locks_sql() -> str:
    relations = ','.join(bench.literal(name)+'::regclass' for name in RELATIONS)
    return f"""select coalesce(jsonb_agg(jsonb_build_object('relation',n.nspname||'.'||c.relname,
 'mode',l.mode,'granted',l.granted) order by c.oid,l.mode),'[]'::jsonb)
 from pg_locks l join pg_class c on c.oid=l.relation join pg_namespace n on n.oid=c.relnamespace
 where l.pid=pg_backend_pid() and l.locktype='relation' and l.relation in ({relations})"""


def sizes_sql() -> str:
    return f"""select jsonb_build_object('navigationTableBytes',pg_relation_size('private.display_navigation_versions_v1'),
 'navigationTotalBytes',pg_total_relation_size('private.display_navigation_versions_v1'),
 'nativeIndexBytes',coalesce(pg_relation_size(to_regclass('private.{bench.NATIVE_CAS_INDEX}')),0))"""


def marker(phase: str, event: str, ordinal: int = -1) -> str:
    # Size helpers may open relations. Sample only after all actual lock-taking
    # work, so instrumentation never precedes the source-before-navigation fence.
    sizes = '('+sizes_sql()+')' if event in ('precommit','commit') else 'null::jsonb'
    return f"""select jsonb_build_object('record','migration-marker','phase',{bench.literal(phase)},
 'event',{bench.literal(event)},'statementOrdinal',{ordinal},'at',clock_timestamp(),'pid',pg_backend_pid(),
 'locks',({relation_locks_sql()}),'sizes',{sizes});\n"""


def instrument_phase(source: str, phase: str) -> str:
    """Insert observations between intact top-level statements, never in bodies."""
    upgrade.migration_statements(source)  # Validate one actual transaction.
    statements = upgrade.split_statements(source)
    result = ["set application_name="+bench.literal(APPLICATION)+";set search_path='';\n"]
    for ordinal, statement in enumerate(statements):
        code = upgrade.statement_code(statement).lower()
        if code == 'commit;':
            result.append(marker(phase,'precommit',ordinal))
        result.append(statement+'\n')
        if code == 'begin;':
            result.append(marker(phase,'start',ordinal))
        elif code == 'commit;':
            result.append(marker(phase,'commit',ordinal))
        elif re.match(r'lock\s+table\b',code):
            result.append(marker(phase,'acquired:lock',ordinal))
        elif re.match(r'alter\s+table\b',code):
            result.append(marker(phase,'acquired:alter',ordinal))
        elif re.match(r'create\s+index\b',code):
            result.append(marker(phase,'acquired:index',ordinal))
    return ''.join(result)


def state_sql() -> str:
    names = "'display_sync_navigation_membership_v1','display_navigation_matched_versions_v1'"
    return f"""select jsonb_build_object('record','state','migrationCount',(select count(*) from supabase_migrations.schema_migrations),
 'migrationHead',(select max(version) from supabase_migrations.schema_migrations),
 'columnExists',exists(select 1 from pg_attribute where attrelid='private.display_navigation_versions_v1'::regclass and attname='cas_number' and not attisdropped),
 'indexExists',to_regclass('private.{bench.NATIVE_CAS_INDEX}') is not null,
 'routines',(select jsonb_object_agg(p.proname,encode(extensions.digest(convert_to(p.prosrc,'UTF8'),'sha256'),'hex'))
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname in ({names})),
 'activeClients',(select count(*) from pg_stat_activity where application_name={bench.literal(APPLICATION)} and pid<>pg_backend_pid()),
 'processVersions',(select count(*) from private.display_navigation_versions_v1 where dataset_kind='process'),
 'flowVersions',(select count(*) from private.display_navigation_versions_v1 where dataset_kind='flow'));
"""


def source_body_hash(definition: str) -> str:
    match = re.search(r'\bAS\s+(\$[A-Za-z_0-9]*\$)(.*?)\1',definition,re.I|re.S)
    if not match: raise ValueError('Expected exact dollar-quoted routine body')
    return bench.sha(match[2])


def validate_initial_state(state: dict, definitions: dict) -> None:
    expected = {name:source_body_hash(value) for (_,name),value in definitions.items()}
    if (state.get('migrationCount'),state.get('migrationHead')) != (439,'20261025052607'):
        raise ValueError('Exact Main 439-migration predecessor required')
    if state.get('columnExists') is not False or state.get('indexExists') is not False or state.get('routines') != expected:
        raise ValueError('Pristine predecessor schema/reader/writer required')
    if any(state.get(key) != 0 for key in ('activeClients','processVersions','flowVersions')):
        raise ValueError('Exact empty owned projection state required')


def control_sql(phase: str) -> str:
    sql = "set application_name="+bench.literal(APPLICATION)+";set search_path='';\n"
    selected = ('facets_all_empty','facets_process_geography','navigation_geography','facets_flow_cas_rare','facets_flow_cas_common')
    for scope in SCOPES:
        cases = bench.cases(scope,'cas-dense')
        for label in selected:
            expression = cases[label].removeprefix('select ')
            sql += f"""begin;set local statement_timeout='8s';set local work_mem='4MB';set local role anon;
with result as materialized (select {expression} as payload)
 select jsonb_build_object('record','response','phase',{bench.literal(phase)},'label',{bench.literal(scope+':'+label)},
 'payload',payload,'canonicalJson',payload::text,'sha256',encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex'),
 'role',current_user,'workMem',current_setting('work_mem'),'statementTimeout',current_setting('statement_timeout')) from result;
rollback;
"""
    return sql


def compare_controls(records: list[dict]) -> list[dict]:
    indexed = {}
    for row in records:
        if row.get('record') != 'response': continue
        key = (row['phase'],row['label'])
        if key in indexed: raise ValueError('Duplicate complete DTO observation')
        if row.get('payload') is None or row.get('canonicalJson') is None or bench.sha(row['canonicalJson']) != row.get('sha256') or json.loads(row['canonicalJson']) != row['payload']:
            raise ValueError('Complete DTO/digest observation required')
        if (row.get('role'),row.get('workMem'),row.get('statementTimeout')) != ('anon','4MB','8s'):
            raise ValueError('Control principal/request budget differs')
        indexed[key] = row
    labels = {row['label'] for row in records if row.get('record')=='response' and row['phase']=='before'}
    if len(labels) != 10 or set(indexed) != {(phase,label) for phase in ('before','after-A','after-B') for label in labels}:
        raise ValueError('Complete three-control/two-CAS/two-scope/three-phase matrix required')
    evidence = []
    for label in sorted(labels):
        for phase in ('after-A','after-B'):
            equal = indexed['before',label]['canonicalJson'] == indexed[phase,label]['canonicalJson']
            evidence.append({'label':label,'phase':phase,'equal':equal})
            if not equal: raise ValueError('Complete response changed: '+phase+':'+label)
    return evidence


def parse_timestamp(value: str) -> datetime:
    # PostgreSQL trims fractional trailing zeroes; Python 3.9 accepts only
    # three or six fractional digits. Normalize without changing the instant.
    value = re.sub(r'\.(\d{1,6})(?=[+-]\d\d:\d\d$)',
                   lambda match: '.' + match[1].ljust(6, '0'), value)
    return datetime.fromisoformat(value)


def lock_evidence(records: list[dict]) -> dict:
    phases = {}
    for phase in ('A','B'):
        rows = [r for r in records if r.get('record')=='migration-marker' and r.get('phase')==phase]
        by_event = {r['event']:r for r in rows if r['event'] in ('start','precommit','commit')}
        if len(by_event) != 3 or any(sum(r['event']==event for r in rows)!=1 for event in by_event):
            raise ValueError('Unique start/precommit/commit observations required')
        timestamps = [parse_timestamp(r['at']) for r in rows]
        if timestamps != sorted(timestamps): raise ValueError('Migration timestamps are not ordered')
        phases[phase] = {'markers':rows,'elapsedToCommitMs':(parse_timestamp(by_event['commit']['at'])-parse_timestamp(by_event['start']['at'])).total_seconds()*1000}
        if any(not lock['granted'] for row in rows for lock in row['locks']):
            raise ValueError('Observed ungranted migration lock')
        if any(lock['mode']=='AccessExclusiveLock' for lock in by_event['commit']['locks']):
            raise ValueError('AccessExclusive lock remains after commit')
    a = phases['A']['markers']; b = phases['B']['markers']
    nav = RELATIONS[2]
    if not any(row['event']=='acquired:alter' and any(lock['relation']==nav and lock['mode']=='AccessExclusiveLock' for lock in row['locks']) for row in a):
        raise ValueError('Phase A ADD COLUMN AccessExclusive evidence missing')
    if not any(lock['relation']==nav and lock['mode']=='AccessExclusiveLock' for lock in next(row for row in a if row['event']=='precommit')['locks']):
        raise ValueError('Phase A AccessExclusive retention before commit unobserved')
    if parse_timestamp(a[-1]['at']) >= parse_timestamp(b[0]['at']):
        raise ValueError('Phase A must commit before phase B starts')
    allowed = {'AccessShareLock','RowExclusiveLock','ShareLock','ShareRowExclusiveLock'}
    if any(lock['mode'] not in allowed for row in b for lock in row['locks']):
        raise ValueError('Phase B observed an ordinary-SELECT-incompatible relation lock')
    precommit = next(row for row in b if row['event']=='precommit')
    if not all(any(lock['relation']==relation and lock['mode']=='ShareRowExclusiveLock' for lock in precommit['locks']) for relation in RELATIONS):
        raise ValueError('Phase B source/navigation writer fences missing')
    if not any(row['event']=='acquired:index' and any(lock['relation']==nav and lock['mode']=='ShareLock' for lock in row['locks']) for row in b):
        raise ValueError('Phase B CREATE INDEX Share evidence missing')
    return phases | {'aAccessExclusiveReleasedBeforeB':True,'bObservedModesAdmitAccessShare':True,
                     'claim':'Observed held modes only; concurrent API/load proof is separate; durations include timestamp/lock marker overhead'}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',required=True,choices=[bench.CONTAINER])
    parser.add_argument('--base-ref',default=BASE,choices=[BASE])
    parser.add_argument('--owner-file',type=Path,default=bench.OWNER,choices=[bench.OWNER])
    parser.add_argument('--report',type=Path,required=True)
    args = parser.parse_args()
    directory = args.report.with_suffix('.artifacts')
    if args.report.exists() or directory.exists(): parser.error('New private report/artifact paths required')
    report = {'schemaVersion':'portal.flow-cas-volume-upgrade.v1','passed':False,
              'classification':'owned local committed synthetic migration-volume/held-lock evidence; not writer throughput, concurrent load or hosted latency',
              'baseCommit':BASE,'rawMigrationExecutionDoesNotAdvanceLedger':True,
              'fixture':bench.fixture_metadata(PROCESS_DATASETS,FLOW_DATASETS,PADDING,'cas-dense',False),
              'modeLimits':{'migrationStatementTimeout':'60s','migrationLockTimeout':'5s','requestStatementTimeout':'8s','requestWorkMem':'4MB',
                            'logBytes':bench.MAX_LOG_BYTES,'stdoutBytes':bench.MAX_STDOUT_BYTES},
              'cleanup':{'resetPerformed':False,'resetOwner':'Main agent; exact owned portal-facets-864 stack','committedSyntheticDataMayRemain':False}}
    admitted = False
    def execute(sql: str, label: str, timeout: int = 180) -> list[dict]:
        stem = directory/label
        with bench.private_output(stem.with_suffix('.sql')) as handle: handle.write(sql.encode())
        completed = bench.run_logged(stem.with_suffix('.sql'),stem.with_suffix('.stdout'),stem.with_suffix('.log'),timeout)
        report.setdefault('executions',[]).append({'label':label,'sqlSha256':bench.sha(sql),'stdoutBytes':stem.with_suffix('.stdout').stat().st_size,'logBytes':stem.with_suffix('.log').stat().st_size,'returncode':completed.returncode})
        if completed.returncode: raise RuntimeError('Local SQL phase failed: '+label+'; inspect private bounded log')
        return [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
    try:
        context = json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
        inspected = json.loads(subprocess.check_output(['docker','inspect',bench.CONTAINER],text=True))[0]
        owner = args.owner_file.read_text()
        bench.validate_target(context,inspected,owner)
        base = subprocess.check_output(['git','rev-parse',args.base_ref+'^{commit}'],cwd=ROOT,text=True).strip()
        if base != BASE: raise ValueError('Exact Main predecessor required')
        definitions = bench.baseline(BASE,[('function',name) for name in ('display_sync_navigation_membership_v1','display_navigation_matched_versions_v1')])
        upgrade.select_profile('869')
        upgrade.load_candidate(BASE,ACTIVATE,PREPARE)
        sources = {'A':PREPARE.read_text(),'B':ACTIVATE.read_text()}
        instrumented = {phase:instrument_phase(source,phase) for phase,source in sources.items()}
        checked = bench.run(bench.guard_sql(),60)
        if checked.returncode or checked.stdout.strip().splitlines()!=bench.empty_guard_expected(): raise ValueError('Exact owned empty PG17.11 database required')
        state = bench.run(state_sql(),60)
        if state.returncode: raise ValueError('Predecessor metadata read failed')
        initial = json.loads(state.stdout)
        validate_initial_state(initial,definitions)
        admitted = True
        args.report.parent.mkdir(parents=True,exist_ok=True)
        directory.mkdir(mode=0o700)
        report.update(initialState=initial,containerId=inspected['Id'],dockerContext=context['Name'],image=inspected['Config']['Image'],
                      resources={k:inspected['HostConfig'].get(k) for k in ('NanoCpus','CpuQuota','CpuPeriod','CpusetCpus','Memory','MemorySwap')},
                      postgresVersion='17.11',ownerSha256=bench.sha(owner),collectorSha256=bench.file_sha(Path(__file__)),
                      benchmarkSha256=bench.file_sha(Path(bench.__file__)),upgradeHelpersSha256=bench.file_sha(Path(upgrade.__file__)),
                      sourceSha256={phase:bench.sha(source) for phase,source in sources.items()})
        for name,source in [('collector.py',Path(__file__).read_bytes()),('prepare.sql',sources['A'].encode()),('activate.sql',sources['B'].encode())]:
            with bench.private_output(directory/name) as handle: handle.write(source)
        seed = bench.fixture(PROCESS_DATASETS,FLOW_DATASETS,PADDING,'cas-dense',False)
        report['fixtureSqlSha256'] = bench.sha(seed)
        report['cleanup']['committedSyntheticDataMayRemain'] = True
        report['fixtureActual'] = execute(seed+'\ncommit;\n'+bench.fixture_summary_sql(False),'seed',900)[0]
        actual = report['fixtureActual']
        if actual['processVersions']!=20000 or actual['flowVersions']!=138000 or actual['publicSourceRows']!=0 or actual['casCounts']!=bench.expected_dense_cas_counts(FLOW_DATASETS):
            raise ValueError('Committed synthetic volume/distribution mismatch')
        records = execute(control_sql('before'),'controls-before')
        records += execute(instrumented['A'],'prepare-A')
        records += execute(control_sql('after-A'),'controls-after-A')
        records += execute(instrumented['B'],'activate-B')
        records += execute(control_sql('after-B'),'controls-after-B')
        report['lockEvidence'] = lock_evidence(records)
        report['completeResponseComparisons'] = compare_controls(records)
        snapshot = execute(bench.native_schema_sql(),'native-schema')[0]
        report['nativeSchemaFingerprint'] = bench.validate_native_schema(snapshot)
        report['nativeSchema'] = snapshot
        report['fixtureAfter'] = execute(bench.fixture_summary_sql(True),'fixture-after')[0]
        counts = bench.expected_dense_cas_counts(FLOW_DATASETS)
        if report['fixtureAfter'].get('nativeCasFact') != {k:counts[k] for k in ('nonNull','rare','common')}|{'mismatches':0}:
            raise ValueError('Committed native fact differs from original CAS predicate')
        report['passed'] = True
    except Exception as exc:
        report['failure'] = type(exc).__name__+': '+str(exc)
    finally:
        if admitted:
            try:
                final = execute(state_sql(),'final-state')[0]
                report['finalState'] = final
                report['cleanup'].update(activeClientsRemaining=final['activeClients'],retainedProcessVersions=final['processVersions'],retainedFlowVersions=final['flowVersions'])
                if final['activeClients'] or (final['migrationCount'],final['migrationHead'])!=(439,'20261025052607'):
                    report['passed'] = False
                    report['cleanup']['failure'] = 'Connections or migration ledger differ'
            except Exception as exc:
                report['passed'] = False
                report['cleanup']['failure'] = type(exc).__name__+': '+str(exc)
        args.report.parent.mkdir(parents=True,exist_ok=True)
        with bench.private_output(args.report) as handle: handle.write((json.dumps(report,indent=2)+'\n').encode())
    print(json.dumps({'report':str(args.report),'passed':report['passed'],'failure':report.get('failure'),'cleanup':report['cleanup']},indent=2))
    return int(not report['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
