#!/usr/bin/env python3
"""Database #869: observe regular/CIC exact-index DDL blocked by B's Nav fence.

Only the empty owned-local canonical Main 439 schema is admitted. Real fixtures
and raw-SQL A/B are committed and retained for an exact owned CLI reset. This
collector does not update migration history or claim hosted timing/CLI proof.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('portal_cas869_cutover_shared', HERE / 'collect_portal_flow_cas_cutover.py')
assert SPEC and SPEC.loader
shared = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shared)
u, bench = shared.upgrade, shared.bench
INDEX = 'private.d807_portal_navigation_versions_flow_cas_v1_idx'
NAV = 'private.display_navigation_versions_v1'


def lock_positions(statements: list[str]) -> tuple[int,int,int]:
    source, nav, preflight = [], [], []
    for index, statement in enumerate(statements):
        code = re.sub(r'\s+', ' ', u.statement_code(statement)).lower()
        if code.startswith('lock table '):
            if 'private.display_catalog_search_rows_v1' in code and 'private.display_catalog_search_rows_v2' in code and 'in share row exclusive mode' in code:
                if code.index('private.display_catalog_search_rows_v1')>=code.index('private.display_catalog_search_rows_v2'):
                    raise ValueError('Existing source writer lock order must be V1 then V2')
                source.append(index)
            if code=='lock table private.display_navigation_versions_v1 in share row exclusive mode;':
                nav.append(index)
        if '$display_flow_cas_preflight$' in statement:
            preflight.append(index)
    if len(source)!=1 or len(nav)!=1 or len(preflight)!=1 or not source[0]<nav[0]<preflight[0]:
        raise ValueError('Exact V1/V2 then Nav SHARE ROW EXCLUSIVE lock before preflight is required')
    return source[0],nav[0],preflight[0]


def exact_index_statement(statements: list[str], concurrent: bool = False) -> str:
    matches=[u.statement_code(s) for s in statements if re.match(r'create\s+index\s+if\s+not\s+exists\b',u.statement_code(s),re.I)]
    if len(matches)!=1 or not re.search(r'\bd807_portal_navigation_versions_flow_cas_v1_idx\b',matches[0]) or 'private.display_navigation_versions_v1' not in matches[0]:
        raise ValueError('Only the exact reviewed native index statement is admitted')
    if concurrent:
        return re.sub(r'^create\s+index\b','create index concurrently',matches[0],count=1,flags=re.I)
    return matches[0]


def fenced_b_sql(statements: list[str], gate: int) -> str:
    _,nav,_=lock_positions(statements)
    lines=['begin;',shared.marker('DDL_B_STARTED')]
    for index,statement in enumerate(statements):
        lines.append(statement)
        if index==nav:
            lines += [shared.marker('DDL_B_NAV_FENCED',"'indexAbsent',to_regclass('"+INDEX+"') is null"),
                      f'select pg_advisory_xact_lock(869,{gate});',shared.marker('DDL_B_PREFLIGHT_RELEASED')]
    lines += [shared.marker('DDL_B_PREPARED',"'indexOid',to_regclass('"+INDEX+"')::oid,'definition',pg_get_indexdef(to_regclass('"+INDEX+"')),'indexBytes',pg_relation_size('"+INDEX+"')"),
              'commit;',shared.marker('DDL_B_COMMITTED')]
    return '\n'.join(lines)


def external_ddl_sql(statements: list[str], concurrent: bool) -> str:
    # Each command autocommits. In particular CIC is never wrapped in BEGIN or DO.
    return "\\set VERBOSITY sqlstate\nset lock_timeout='5s';set statement_timeout='60s';\n"+shared.marker('EXTERNAL_DDL_STARTED')+'\n'+exact_index_statement(statements,concurrent)+'\n'+shared.marker('EXTERNAL_DDL_COMPLETED',"'indexOid',to_regclass('"+INDEX+"')::oid,'definition',pg_get_indexdef(to_regclass('"+INDEX+"'))")


def observe_nav_wait(c, name: str, blocker: str, mode: str) -> dict:
    pid,blocker_pid=c.pids[name],c.pids[blocker]
    app=bench.literal(c.prefix+name)
    predicate=f"s.pid={pid} and s.application_name={app} and s.state='active' and s.wait_event_type='Lock' and lower(s.wait_event)='relation' and {blocker_pid}=any(pg_blocking_pids(s.pid)) and exists(select 1 from pg_locks l where l.pid=s.pid and l.locktype='relation' and l.relation='{NAV}'::regclass and l.mode={bench.literal(mode)} and not l.granted)"
    sql=f"""do $observe$declare deadline timestamptz:=clock_timestamp()+interval '1 second';begin
 loop
  perform pg_stat_clear_snapshot();
  exit when exists(select 1 from pg_stat_activity s where {predicate});
  if clock_timestamp()>deadline then raise exception 'Exact concurrent index DDL Nav wait not observed';end if;
  perform pg_sleep(0.002);
 end loop;
end$observe$;
select jsonb_build_object('pid',s.pid,'application',s.application_name,'waitEvent',s.wait_event,
 'queryStartEpoch',extract(epoch from s.query_start),'observedEpoch',extract(epoch from clock_timestamp()),
 'blockers',pg_blocking_pids(s.pid),'requestedMode',{bench.literal(mode)},
 'blockingNavLock',(select jsonb_agg(jsonb_build_object('mode',l.mode,'granted',l.granted)) from pg_locks l where l.pid={blocker_pid} and l.relation='{NAV}'::regclass))
from pg_stat_activity s where {predicate};"""
    rows=c.call('observe-'+name,sql,10)
    if len(rows)!=1 or not any(lock['mode']=='ShareRowExclusiveLock' and lock['granted'] for lock in rows[0]['blockingNavLock']):
        raise ValueError('Actual granted B Nav SHARE ROW EXCLUSIVE must block the exact DDL waiter')
    return rows[0]


def external_outcome(session) -> dict:
    try:
        row=shared.parse_marker(session,'EXTERNAL_DDL_COMPLETED',10)
        return {'completed':True,'receipt':row,'sqlstate':None}
    except RuntimeError:
        if session.process.poll() is None:
            try:
                session.process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                raise RuntimeError('Concurrent exact-index DDL did not finish within its bounded marker wait')
        session.close()
        stderr=''.join(session.errors)
        # Both acceptable outcomes are safe: IF NOT EXISTS may skip the now
        # committed name, or the namespace race may report duplicate_table.
        if not re.search(r'\b42P07\b',stderr):
            raise RuntimeError('Concurrent exact-index DDL failed with an unexpected SQLSTATE')
        return {'completed':False,'sqlstate':'42P07','exitCode':session.process.returncode}


def run(c) -> None:
    gate=int(hashlib.sha256(c.nonce.encode()).hexdigest()[:8],16)%2000000000+1
    controller=c.session('ddl-controller')
    c.send(controller,'ddl-exclusive-fixture',"do $$begin if not pg_try_advisory_lock(864,1) then raise exception 'Another owned fixture is active';end if;end$$;"+f'select pg_advisory_lock(869,{gate});'+shared.marker('DDL_OWNED'))
    shared.parse_marker(controller,'DDL_OWNED')
    c.call('ddl-locked-canonical',shared.canonical_guard(c.predecessor))
    c.util_original=c.call('ddl-original-webhook',"select jsonb_build_object('definition',pg_get_functiondef('util.invoke_edge_function(text,jsonb,integer)'::regprocedure));")[0]['definition']
    seed=u.source_fixture().replace('create extension if not exists pgtap with schema extensions;','')
    c.call('ddl-seed-before-a','begin;'+seed+'\ncommit;')
    c.report['fixtureRetained']=c.report['resetRequired']=True
    c.restore_webhook()
    c.report['phaseA']=c.call('ddl-commit-a','begin;'+'\n'.join(c.phases.prepare)+"commit;select jsonb_build_object('commitObservedEpoch',extract(epoch from clock_timestamp()),'indexAbsent',to_regclass('"+INDEX+"') is null);")[0]
    if not c.report['phaseA']['indexAbsent']:
        raise ValueError('DDL fence requires an initially absent activation index')
    c.report['phaseACommitted']=True
    before=shared.one_facets(c,'ddl-before-b-reader')
    before_data=shared.logical_data(c,'ddl-before-b-logical-data')
    phase=c.session('ddl-phase-b')
    c.send(phase,'actual-b-with-nav-boundary',fenced_b_sql(c.phases.activate,gate))
    started=shared.parse_marker(phase,'DDL_B_STARTED')
    fenced=shared.parse_marker(phase,'DDL_B_NAV_FENCED')
    if not fenced['indexAbsent']:
        raise ValueError('External DDL must begin before B preflight and native index creation')
    regular=c.session('regular-index')
    cic=c.session('concurrent-index')
    c.send(regular,'regular-exact-native-index',external_ddl_sql(c.phases.activate,False))
    regular_started=shared.parse_marker(regular,'EXTERNAL_DDL_STARTED')
    regular_wait=observe_nav_wait(c,'regular-index','ddl-phase-b','ShareLock')
    c.send(cic,'concurrent-exact-native-index',external_ddl_sql(c.phases.activate,True))
    cic_started=shared.parse_marker(cic,'EXTERNAL_DDL_STARTED')
    cic_wait=observe_nav_wait(c,'concurrent-index','ddl-phase-b','ShareUpdateExclusiveLock')
    during=shared.one_facets(c,'ddl-reader-while-nav-fenced')
    if during['payload']!=before['payload']:
        raise ValueError('Nav fence changed complete anonymous reader DTO before activation')
    c.release(controller,'DDL_RELEASE_B_PREFLIGHT',gate)
    released=shared.parse_marker(phase,'DDL_B_PREFLIGHT_RELEASED')
    prepared=shared.parse_marker(phase,'DDL_B_PREPARED')
    committed=shared.parse_marker(phase,'DDL_B_COMMITTED')
    c.report['phaseBCommitted']=True
    regular_result=external_outcome(regular)
    cic_result=external_outcome(cic)
    for result in (regular_result,cic_result):
        if result['completed'] and (result['receipt']['indexOid']!=prepared['indexOid'] or result['receipt']['definition']!=prepared['definition']):
            raise ValueError('Concurrent DDL replaced or changed the B-created native index')
    c.call('ddl-final-native-contract',u.native_assert_sql(True))
    after=shared.one_facets(c,'ddl-after-b-reader')
    after_data=shared.logical_data(c,'ddl-after-b-logical-data')
    metadata=c.call('ddl-final-native-metadata',u.catalog_query()+';')[0]
    if metadata['nativeExtension']['index']['catalog']['indexrelid']!=prepared['indexOid']:
        raise ValueError('B-created activation index OID did not survive concurrent DDL unchanged')
    if after['payload']!=before['payload'] or before_data!=after_data:
        raise ValueError('Concurrent DDL activation changed public DTOs or old projection/source data')
    c.report.update({'passed':True,'classification':'Actual regular/CIC exact-index waiters blocked by B Nav SRE before preflight; raw A/B commits, no migration ledger transition',
        'phaseB':{'started':started,'navFenceAcquired':fenced,'preflightReleased':released,'prepared':prepared,'commitObserved':committed},
        'regularIndex':{'started':regular_started,'observedWait':regular_wait,'outcome':regular_result},
        'concurrentIndex':{'started':cic_started,'observedWait':cic_wait,'outcome':cic_result},
        'readerBefore':before,'readerWhileNavFenced':during,'readerAfter':after,
        'sameCompletePublicDto':True,'samePublicAndOldProjectionData':True,
        'nonNativeDataBefore':before_data,'nonNativeDataAfter':after_data,
        'activationIndexOidUnchanged':True,'finalNativeExtension':metadata['nativeExtension']})


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.set_defaults(mode='ddl-fence')
    parser.add_argument('--container',choices=[bench.CONTAINER],required=True)
    parser.add_argument('--base-ref',required=True)
    parser.add_argument('--owner-file',type=Path,choices=[bench.OWNER],default=bench.OWNER)
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    if args.report.suffix!='.json' or not args.report.resolve().is_relative_to(bench.OWNER.parent.resolve()) or any(args.report.with_suffix(ext).exists() for ext in ('.json','.sql','.log')):
        parser.error('New private owner-directory JSON/SQL/log evidence paths required')
    try:
        base=subprocess.check_output(['git','rev-parse',args.base_ref+'^{commit}'],cwd=u.ROOT,text=True).strip()
        _,source,phases=u.load_candidate(base,None)
        lock_positions(phases.activate)
        exact_index_statement(phases.activate)
        predecessor=bench.baseline(base,list(bench.reader_definitions(source)))
        context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
        inspected=json.loads(subprocess.check_output(['docker','inspect',args.container],text=True))[0]
        bench.validate_target(context,inspected,args.owner_file.read_text())
        empty=bench.run(bench.guard_sql(),60)
        if empty.returncode or empty.stdout.strip().splitlines()!=bench.empty_guard_expected():
            raise ValueError('Empty exact owned local PG17.11 target required; canonical CLI reset first')
        result=u.visibility_run('portal869-ddl-fence-initial-admission',shared.canonical_guard(predecessor)+u.catalog_query()+';',60)
        if result.returncode:
            raise ValueError('Canonical Main 439 schema/head admission failed')
        initial=json.loads(result.stdout)
    except (OSError,ValueError,subprocess.CalledProcessError,subprocess.TimeoutExpired) as exc:
        parser.error(str(exc))
    args.report.parent.mkdir(parents=True,exist_ok=True)
    c=shared.Collector(args,predecessor,phases,source,context,inspected,initial)
    c.report['harnessSha256']=bench.sha(Path(__file__).read_bytes())
    c.report['sharedCollectorSha256']=bench.sha((HERE/'collect_portal_flow_cas_cutover.py').read_bytes())
    try:
        run(c)
    except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as exc:
        c.report['passed']=False
        c.report['failure']=str(exc)
    finally:
        try:
            c.cleanup_sessions()
            # If B aborted, an external CIC may have acquired its queued lock
            # during rollback and committed the exact test index. The initial
            # admission proved this name absent; A never creates it. Remove only
            # that owned artifact when the canonical matcher is still active.
            state=c.call('ddl-owned-index-disposition',"select jsonb_build_object('nativeMatcher',strpos(pg_get_functiondef('private.display_navigation_matched_versions_v1(text,text,jsonb)'::regprocedure),'display-flow-cas-native-v1')>0,'indexPresent',to_regclass('"+INDEX+"') is not null);")[0]
            if state['indexPresent'] and not state['nativeMatcher']:
                c.call('ddl-remove-aborted-external-index',"set lock_timeout='5s';set statement_timeout='60s';drop index "+INDEX+';'+bench.REFRESH)
                c.report['ownedExternalIndexRemovedAfterAbortedB']=True
            c.report['cleanupActivationWitness']=state
            rows=c.call('ddl-cleanup',u.catalog_query()+";select jsonb_build_object('nonceSessions',(select count(*) from pg_stat_activity where pid<>pg_backend_pid() and application_name like "+bench.literal(c.prefix+'%')+"),'fixtureExclusiveLockReleased',pg_try_advisory_xact_lock(864,1),'manifestValid',(select identity=private.portal_display_contract_identity_v1() from private.portal_display_contract_manifest where singleton),'processRows',(select count(*) from public.processes),'flowRows',(select count(*) from public.flows),'settingsRows',(select count(*) from private.dataset_display_settings));",30)
            if len(rows)!=2:
                raise ValueError('Complete exact DDL cleanup receipt required')
            metadata,receipt=rows
            if receipt['nonceSessions'] or not receipt['fixtureExclusiveLockReleased'] or not receipt['manifestValid'] or metadata['migrationHead']!=shared.CANONICAL_MIGRATION:
                raise ValueError('DDL collector leaked an owned session/lock, manifest drift or ledger change')
            retained=bool(receipt['processRows'] or receipt['flowRows'] or receipt['settingsRows'])
            c.report.update({'fixtureRetained':retained,'resetRequired':retained,
                'cleanup':receipt|{'containersCreated':0,'volumesCreated':0,'retainedNativeSchema':metadata['nativeExtension']['column'] is not None,
                'disposition':'Retain real fixture and raw A/B schema for exact owned CLI reset; no ledger transition'}})
        except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as exc:
            c.report['passed']=False
            c.report['cleanupFailure']=str(exc)
        c.finish_files()
    print(json.dumps({'report':str(args.report),'passed':c.report['passed'],'resetRequired':c.report['resetRequired'],'failure':c.report.get('failure'),'cleanup':c.report['cleanup']},indent=2))
    return int(not c.report['passed'])


if __name__=='__main__':
    sys.exit(main())
