#!/usr/bin/env python3
"""Database #869: owned-local queued-writer fences or rollback-only writer WAL.

Requires the empty canonical Main 439 schema/migration head, never a hosted DSN.
Fence mode commits real fixtures plus raw-SQL A/B and deliberately retains them
for an owned CLI reset; it does not change the migration ledger. Cost mode rolls
back every logical change and measures statements, not production latency.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import queue
import re
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('portal_cas869_upgrade', HERE / 'test_portal_facets_navigation_upgrade.py')
assert SPEC and SPEC.loader
upgrade = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upgrade)
upgrade.select_profile('869')
bench = upgrade.bench
CANONICAL_MIGRATION = '20261025052607'
CAS_PATH = '{flowDataSet,flowInformation,dataSetInformation,CASNumber}'
TARGET_ONE = '86900000-0000-4000-8000-000000000101'
TARGET_TWO = '86900000-0000-4000-8000-000000000102'
NATIVE_INDEX = 'private.d807_portal_navigation_versions_flow_cas_v1_idx'


def writer_fixture() -> str:
    """Keep batch/queued update targets editable at insertion, with guards on."""
    source = upgrade.source_fixture()
    for suffix in ('102', '109'):
        original = "('86900000-0000-4000-8000-000000000" + suffix + "','01.00.000',100,"
        if source.count(original) != 1:
            raise ValueError('Exact editable writer fixture insertion not found')
        source = source.replace(original, original.replace(',100,', ',0,'))
    return source


def routine_body(source: str) -> str:
    match = re.search(r'\bAS\s+(\$[A-Za-z_0-9]*\$)', source, re.I)
    if not match:
        raise ValueError('One dollar-quoted canonical routine body required')
    end = source.find(match[1], match.end())
    if end < 0:
        raise ValueError('Unterminated canonical routine body')
    return source[match.end():end]


def canonical_guard(predecessor: dict) -> str:
    clauses = []
    for (_, name), source in predecessor.items():
        signature = ('private.display_sync_navigation_membership_v1(text,uuid,text,jsonb)'
                     if name == 'display_sync_navigation_membership_v1'
                     else 'private.display_navigation_matched_versions_v1(text,text,jsonb)')
        clauses.append(f"(select prosrc from pg_proc where oid={bench.literal(signature)}::regprocedure) is distinct from {bench.literal(routine_body(source))}")
    empty = ' or '.join('exists(select 1 from ' + table + ')' for table in bench.TABLES)
    return """
do $canonical$
begin
 if inet_server_addr() is not null or current_setting('server_version')<>'17.11'
  or (select max(version) from supabase_migrations.schema_migrations) is distinct from '20261025052607'
  or exists(select 1 from pg_attribute where attrelid='private.display_navigation_versions_v1'::regclass and attname='cas_number' and not attisdropped)
  or to_regclass('private.d807_portal_navigation_versions_flow_cas_v1_idx') is not null then
  raise exception 'Exact canonical Main 439 local schema/head without native extension required; CLI reset first';
 end if;
 if """ + ' or '.join(clauses) + """ then
  raise exception 'Canonical Main predecessor routine bodies differ';
 end if;
 perform private.portal_display_assert_contract_v1();
 if """ + empty + """ then
  raise exception 'Canonical cutover collector requires every owned fixture table empty';
 end if;
end$canonical$;
"""


def update_sql(target: str, cas: str) -> str:
    return ("update public.flows set json=jsonb_set(json," + bench.literal(CAS_PATH) + ','
            + bench.literal(json.dumps(cas)) + "::jsonb) where id=" + bench.literal(target)
            + "::uuid and version='01.00.000' returning id")


def marker(label: str, fields: str = '') -> str:
    extra = ',' + fields if fields else ''
    return "select " + bench.literal(label + ':') + "||jsonb_build_object('pid',pg_backend_pid(),'epoch',extract(epoch from clock_timestamp())" + extra + ')::text;'


def parse_marker(session, label: str, timeout: int = 10) -> dict:
    return json.loads(session.marker(label + ':', timeout).partition(':')[2])


class Collector:
    def __init__(self, args, predecessor, phases, source, context, inspected, initial):
        self.args, self.predecessor, self.phases = args, predecessor, phases
        self.nonce = uuid.uuid4().hex[:12]
        self.prefix = 'portal869-cutover-' + self.nonce + '-'
        self.ordinal = 0
        self.sessions = []
        self.pids = {}
        self.transcript, self.logs = [], []
        self.util_original = None
        self.brand_original = None
        self.report = {'schemaVersion': 'portal.flow-cas-cutover-cost.v1', 'mode': args.mode,
            'passed': False, 'nonce': self.nonce, 'applicationNamePrefix': self.prefix,
            'containerId': inspected['Id'], 'image': inspected['Config']['Image'],
            'dockerContext': context['Name'], 'baseCommit': upgrade.CAS_BASE,
            'ownerSha256': bench.sha(args.owner_file.read_bytes()),
            'initialMigrationHead': initial['migrationHead'], 'canonicalInitialSchemaVerified': True,
            'baselineReconstruction': False, 'migrationLedgerTransition': False,
            'harnessSha256': bench.sha(Path(__file__).read_bytes()),
            'sourceFixtureSha256': bench.sha(writer_fixture() if args.mode in ('cost','fence') else upgrade.source_fixture()),
            'writerFixture': 'batch and queued source targets inserted as editable drafts; all source/review guards enabled' if args.mode in ('cost','fence') else 'original real-source fixture',
            'orderedMigrationBundle': [{'path': str(upgrade.PROFILES['869'][key].relative_to(upgrade.ROOT)),
                'sha256': bench.sha(upgrade.PROFILES['869'][key].read_bytes())} for key in ('prepare','candidate')],
            'bundleSha256': bench.sha(source), 'fixtureRetained': False, 'resetRequired': False,
            'phaseACommitted': False, 'phaseBCommitted': False,
            'statementBudget': '8s public reads; original 5s product lock timeout; 60s administrative statement timeout',
            'unresolvedProof': ['hosted latency', 'migration ledger application; owned CLI/CI proof is separate'],
            'initialMetadata': initial, 'cleanup': None}

    def call(self, label: str, sql: str, timeout: int = 60) -> list[dict]:
        self.ordinal += 1
        app = self.prefix + label + '-' + str(self.ordinal)
        full = "set search_path='';\n" + sql
        self.transcript.append('-- ' + app + '\n' + full)
        result = upgrade.visibility_run(app, full, timeout)
        self.logs.append('-- ' + app + '\n' + result.stdout + '\n' + result.stderr)
        if result.returncode:
            raise RuntimeError('Owned local SQL failed: ' + label)
        return [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]

    def session(self, name: str):
        session = upgrade.VisibilitySession(self.prefix + name)
        self.sessions.append(session)
        session.send("set search_path='';" + marker('SESSION_READY'))
        row = parse_marker(session, 'SESSION_READY')
        self.pids[name] = row['pid']
        return session

    def send(self, session, label: str, sql: str):
        self.transcript.append('-- ' + label + '\n' + sql)
        session.send(sql)

    def observe(self, label: str, name: str, blocker: str, relation: bool) -> dict:
        pid, blocking_pid = self.pids[name], self.pids[blocker]
        app = bench.literal(self.prefix + name)
        predicate = f"s.pid={pid} and s.application_name={app} and s.state='active' and s.wait_event_type='Lock' and {blocking_pid}=any(pg_blocking_pids(s.pid))"
        if relation:
            predicate += " and lower(s.wait_event)='relation' and exists(select 1 from pg_locks l where l.pid=s.pid and l.locktype='relation' and l.relation='private.display_catalog_search_rows_v1'::regclass and not l.granted)"
        else:
            predicate += " and lower(s.wait_event)='advisory'"
        sql = f"""do $observe$declare deadline timestamptz:=clock_timestamp()+interval '1 second';begin
 loop
  perform pg_stat_clear_snapshot();
  exit when exists(select 1 from pg_stat_activity s where {predicate});
  if clock_timestamp()>deadline then raise exception 'Required exact nonce relation/advisory wait not observed';end if;
  perform pg_sleep(0.002);
 end loop;
end$observe$;
select jsonb_build_object('pid',s.pid,'application',s.application_name,'waitEvent',s.wait_event,
 'queryStartEpoch',extract(epoch from s.query_start),'backendXmin',s.backend_xmin::text,
 'blockers',pg_blocking_pids(s.pid),'epoch',extract(epoch from clock_timestamp()),
 'relationLocks',(select jsonb_agg(jsonb_build_object('relation',l.relation::regclass::text,'mode',l.mode,'granted',l.granted)) from pg_locks l where l.pid=s.pid and l.locktype='relation' and l.relation='private.display_catalog_search_rows_v1'::regclass))
from pg_stat_activity s where {predicate};"""
        rows = self.call(label, sql, 10)
        if len(rows) != 1:
            raise ValueError('One observed exact nonce waiter is required')
        return rows[0]

    def capture(self, label: str, replay: bool = False) -> dict:
        sql = 'begin;set local work_mem=\'4MB\';\n'
        if replay:
            sql += upgrade.matcher_replay(self.predecessor)
        sql += upgrade.visibility_read_sql() + '\nrollback;'
        rows = self.call(label, sql, 30)
        if len(rows) != 1 or rows[0]['readerRole'] != 'anon' or rows[0]['readerPid'] in self.pids.values():
            raise ValueError('An independent anonymous full DTO reader is required')
        if set(rows[0]['responses']) != set(upgrade.visibility_queries()):
            raise ValueError('Complete scoped anonymous DTO response required')
        self.report.setdefault('readerConnections', {})[label] = {k: rows[0][k] for k in ('readerRole','readerPid','readerApplication')}
        return rows[0]['responses']

    def phase_sql(self, name: str, statements: list[str], gate: int) -> str:
        lines = ['begin;', marker(name + '_STARTED')]
        for statement in statements:
            lines.append(statement)
            if re.match(r'lock\s+table\b', upgrade.statement_code(statement), re.I):
                lines.append(marker(name + '_LOCKED'))
        lines += [marker(name + '_PREPARED', "'nativeIndexBytes',coalesce(pg_relation_size(to_regclass('" + NATIVE_INDEX + "')),0),'navigationTableBytes',pg_relation_size('private.display_navigation_versions_v1')"),
                  f'select pg_advisory_xact_lock(869,{gate});', 'commit;', marker(name + '_COMMITTED')]
        return '\n'.join(lines)

    def source_writer(self, session, label: str, target: str, cas: str, gate: int):
        key = "dataset_kind='flow' and id=" + bench.literal(target) + "::uuid and version='01.00.000'"
        facts = "'projectedCas',(select card->>'casNumber' from private.display_catalog_search_rows_v1 where " + key + "),'nativeCas',(select to_jsonb(n)->>'cas_number' from private.display_navigation_versions_v1 n where " + key + ')'
        self.send(session, label, "begin;set local lock_timeout='5s';set local statement_timeout='60s';\n"
            + update_sql(target, cas) + ';\n' + marker(label + '_MUTATED',facts)
            + f'\nselect pg_advisory_xact_lock(869,{gate});commit;\n' + marker(label + '_COMMITTED'))

    def release(self, controller, label: str, gate: int):
        controller.send(f'select pg_advisory_unlock(869,{gate});' + marker(label))
        return parse_marker(controller, label)

    def finish_files(self):
        sql_path = self.args.report.with_suffix('.sql')
        log_path = self.args.report.with_suffix('.log')
        with bench.private_output(sql_path) as output:
            output.write(('\n'.join(self.transcript) + '\n').encode())
        for session in self.sessions:
            self.logs.append('-- ' + session.application + '\n' + ''.join(session.lines) + '\n' + ''.join(session.errors))
        with bench.private_output(log_path) as output:
            output.write(('\n'.join(self.logs) + '\n').encode())
        self.report.update({'sqlPath': str(sql_path), 'sqlSha256': bench.sha(sql_path.read_bytes()), 'logPath': str(log_path)})
        with bench.private_output(self.args.report) as output:
            output.write((json.dumps(self.report, indent=2) + '\n').encode())

    def cleanup_sessions(self):
        # Safe at any failed marker, including before fixture seeding. Requiring
        # exact nonce application AND observed PID avoids touching another run.
        for session in reversed(self.sessions):
            if session.process.poll() is None:
                pid = self.pids.get(session.application.removeprefix(self.prefix))
                predicate = 'application_name=' + bench.literal(session.application)
                if pid is not None:
                    predicate += f' and pid={pid}'
                self.call('terminate-owned-session', "select jsonb_build_object('terminated',coalesce(bool_and(pg_terminate_backend(pid)),true)) from pg_stat_activity where " + predicate + ';', 10)
                session.close()
        if self.util_original is not None and not self.report.get('webhookRestored'):
            self.restore_webhook()
        if self.brand_original is not None and not self.report.get('brandHelperRestored'):
            self.restore_brand()

    def restore_webhook(self):
        restore = self.util_original.rstrip().rstrip(';')+';'
        rows = self.call('restore-webhook',restore+"select jsonb_build_object('restored',pg_get_functiondef('util.invoke_edge_function(text,jsonb,integer)'::regprocedure)="+bench.literal(self.util_original)+');')
        if len(rows)!=1 or rows[0]!={'restored':True}:
            raise ValueError('Exact original external-webhook helper readback failed')
        self.report['webhookRestored'] = True

    def restore_brand(self):
        restore = self.brand_original.rstrip().rstrip(';')+';'
        rows = self.call('restore-brand-helper',restore+bench.REFRESH+"select private.portal_display_assert_contract_v1();select jsonb_build_object('restored',pg_get_functiondef('private.portal_display_brand_facets_v1(jsonb,text,text,jsonb)'::regprocedure)="+bench.literal(self.brand_original)+');')
        if len(rows)!=1 or rows[0]!={'restored':True}:
            raise ValueError('Exact original brand helper readback failed')
        self.report['brandHelperRestored'] = True


def fence_run(c: Collector) -> None:
    gate_base = int(hashlib.sha256(c.nonce.encode()).hexdigest()[:8], 16) % 2000000000
    old_gate, phase_gate, queue_gate = (gate_base + n for n in (1,2,3))
    controller = c.session('controller')
    c.send(controller, 'owned-fixture-and-gates', "do $$begin if not pg_try_advisory_lock(864,1) then raise exception 'Another fixture owns this database';end if;end$$;"
        + ''.join(f'select pg_advisory_lock(869,{gate});' for gate in (old_gate,phase_gate,queue_gate)) + marker('OWNED'))
    parse_marker(controller, 'OWNED')
    guarded = c.call('locked-empty-and-canonical', bench.guard_sql() + canonical_guard(c.predecessor))
    # guard_sql emits scalar lines, canonical_guard raises on any mismatch.
    util_rows = c.call('original-webhook', "select jsonb_build_object('definition',pg_get_functiondef('util.invoke_edge_function(text,jsonb,integer)'::regprocedure));")
    util_original = util_rows[0]['definition']
    c.util_original = util_original
    c.report['webhookDefinitionSha256'] = bench.sha(util_original)
    c.report['externalWebhookStub'] = 'temporary owned-local util stub retained until final restoration; projection/source/settings writers enabled'
    try:
        seed = writer_fixture().replace('create extension if not exists pgtap with schema extensions;', '')
        c.call('commit-real-fixture', "begin;set local statement_timeout='60s';\n" + seed + '\ncommit;')
        c.report['fixtureRetained'] = c.report['resetRequired'] = True
        old = c.session('old-writer')
        queued = c.session('queued-writer')
        warmed = {}
        for name, session, target in (('old-writer',old,TARGET_ONE),('queued-writer',queued,TARGET_TWO)):
            c.send(session, 'warm-canonical-helper-' + name,
                'begin;' + update_sql(target,'67-56-1') + ';rollback;' + marker('WARMED'))
            warmed[name] = parse_marker(session, 'WARMED')
        c.report['warmCanonicalHelperSessions'] = warmed
        c.source_writer(old, 'A_OLD_WRITER', TARGET_ONE, '64-17-5', old_gate)
        old_mutated_a = parse_marker(old, 'A_OLD_WRITER_MUTATED')
        if old_mutated_a['projectedCas']!='64-17-5' or old_mutated_a['nativeCas'] is not None:
            raise ValueError('Canonical warm source writer did not exercise the pre-A body')
        c.observe('old-writer-held', 'old-writer', 'controller', False)
        phase_a = c.session('phase-a')
        c.send(phase_a,'actual-phase-a',c.phase_sql('A',c.phases.prepare,phase_gate))
        started_a = parse_marker(phase_a,'A_STARTED')
        waiting_a = c.observe('phase-a-source-fence','phase-a','old-writer',True)
        c.source_writer(queued,'A_QUEUED_WRITER',TARGET_TWO,'67-56-1',queue_gate)
        queued_a = c.observe('queued-writer-after-a-fence','queued-writer','phase-a',True)
        c.release(controller,'RELEASE_OLD_A',old_gate)
        old_commit_a = parse_marker(old,'A_OLD_WRITER_COMMITTED')
        locked_a = parse_marker(phase_a,'A_LOCKED')
        prepared_a = parse_marker(phase_a,'A_PREPARED')
        c.release(controller,'RELEASE_PHASE_A',phase_gate)
        committed_a = parse_marker(phase_a,'A_COMMITTED')
        c.report['phaseACommitted'] = True
        queued_mutated_a = parse_marker(queued,'A_QUEUED_WRITER_MUTATED')
        if queued_mutated_a['projectedCas']!='67-56-1' or queued_mutated_a['nativeCas']!='67-56-1':
            raise ValueError('Queued warm writer did not synchronously adopt the prepared native helper')
        c.release(controller,'RELEASE_QUEUE_A',queue_gate)
        queued_commit_a = parse_marker(queued,'A_QUEUED_WRITER_COMMITTED')
        facts_a = c.call('phase-a-queued-writer-facts', """select jsonb_build_object(
 'oldWriterCas',(select card->>'casNumber' from private.display_catalog_search_rows_v1 where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000101' and version='01.00.000'),
 'oldWriterNative',(select cas_number from private.display_navigation_versions_v1 where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000101' and version='01.00.000'),
 'queuedWriterCas',(select card->>'casNumber' from private.display_catalog_search_rows_v1 where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000102' and version='01.00.000'),
 'queuedWriterNative',(select cas_number from private.display_navigation_versions_v1 where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000102' and version='01.00.000'));
""")[0]
        if facts_a != {'oldWriterCas':'64-17-5','oldWriterNative':None,'queuedWriterCas':'67-56-1','queuedWriterNative':'67-56-1'}:
            raise ValueError('Warm queued source writer did not adopt the committed prepared CAS writer')
        phase_a_read = c.capture('phase-a-anonymous')
        if c.capture('phase-a-canonical-reader-replay',True) != phase_a_read:
            raise ValueError('Committed prepared schema changed old-reader complete DTOs')
        c.report['phaseA'] = {'started':started_a,'observedSourceFence':waiting_a,'observedQueuedWriter':queued_a,
            'oldWriterMutated':old_mutated_a,
            'oldWriterCommitObserved':old_commit_a,'lockAcquired':locked_a,'prepared':prepared_a,'commitObserved':committed_a,
            'queuedWriterMutated':queued_mutated_a,'queuedWriterCommitObserved':queued_commit_a,'facts':facts_a,
            'fullDtoComparisons':len(phase_a_read),'ddlElapsedAfterLockMs':1000*(prepared_a['epoch']-locked_a['epoch'])}
        # Reacquire gates only after the previous holders have visibly committed.
        controller.send(''.join(f'select pg_advisory_lock(869,{gate});' for gate in (old_gate,phase_gate,queue_gate)) + marker('GATES_REACQUIRED'))
        parse_marker(controller,'GATES_REACQUIRED')
        c.source_writer(old,'B_OLD_WRITER',TARGET_ONE,'75-07-0',old_gate)
        old_mutated_b = parse_marker(old,'B_OLD_WRITER_MUTATED')
        if old_mutated_b['projectedCas']!='75-07-0' or old_mutated_b['nativeCas']!='75-07-0':
            raise ValueError('Source writer before B left its native CAS stale')
        phase_b = c.session('phase-b')
        c.send(phase_b,'actual-phase-b',c.phase_sql('B',c.phases.activate,phase_gate))
        started_b = parse_marker(phase_b,'B_STARTED')
        waiting_b = c.observe('phase-b-source-fence','phase-b','old-writer',True)
        c.source_writer(queued,'B_QUEUED_WRITER',TARGET_TWO,'64-17-5',queue_gate)
        queued_b = c.observe('queued-writer-after-b-fence','queued-writer','phase-b',True)
        c.release(controller,'RELEASE_OLD_B',old_gate)
        old_commit_b = parse_marker(old,'B_OLD_WRITER_COMMITTED')
        locked_b = parse_marker(phase_b,'B_LOCKED')
        prepared_b = parse_marker(phase_b,'B_PREPARED')
        during_b = c.capture('phase-b-before-commit-old-reader')
        c.release(controller,'RELEASE_PHASE_B',phase_gate)
        committed_b = parse_marker(phase_b,'B_COMMITTED')
        c.report['phaseBCommitted'] = True
        queued_mutated_b = parse_marker(queued,'B_QUEUED_WRITER_MUTATED')
        if queued_mutated_b['projectedCas']!='64-17-5' or queued_mutated_b['nativeCas']!='64-17-5':
            raise ValueError('Queued source writer after B left its native CAS stale')
        c.observe('queued-writer-held-after-b','queued-writer','controller',False)
        after_b = c.capture('phase-b-after-commit-new-reader')
        if during_b != after_b:
            raise ValueError('Full DTO changed across B commit on the same committed source generation')
        c.release(controller,'RELEASE_QUEUE_B',queue_gate)
        queued_commit_b = parse_marker(queued,'B_QUEUED_WRITER_COMMITTED')
        final_read = c.capture('final-candidate-reader')
        if c.capture('final-canonical-reader-replay',True) != final_read:
            raise ValueError('Final native reader differs from canonical reader on the same committed sources')
        c.call('validate-final-native-facts',upgrade.native_assert_sql(True))
        c.report['phaseB'] = {'started':started_b,'observedSourceFence':waiting_b,'observedQueuedWriter':queued_b,
            'oldWriterMutated':old_mutated_b,'queuedWriterMutated':queued_mutated_b,
            'oldWriterCommitObserved':old_commit_b,'lockAcquired':locked_b,'prepared':prepared_b,'commitObserved':committed_b,
            'queuedWriterCommitObserved':queued_commit_b,'readerBeforeCommit':during_b,'readerAfterCommit':after_b,
            'finalReader':final_read,'fullDtoComparisons':2*len(final_read),
            'ddlElapsedAfterLockMs':1000*(prepared_b['epoch']-locked_b['epoch'])}
        c.report['passed'] = True
    finally:
        # First terminate only explicitly owned nonce sessions so no test lock can
        # prevent exact restoration of the external-webhook helper.
        for session in reversed(c.sessions):
            if session is controller:
                continue
            if session.process.poll() is None:
                pid = c.pids.get(session.application.removeprefix(c.prefix))
                c.call('terminate-owned-session',"select jsonb_build_object('terminated',coalesce(bool_and(pg_terminate_backend(pid)),true)) from pg_stat_activity where application_name=" + bench.literal(session.application) + (f' and pid={pid}' if pid is not None else '') + ';',10)
                session.close()
        controller.close()
        c.restore_webhook()


def barrier_brand_definition(original: str, gate: int) -> str:
    """Value-preserving local instrumentation around the existing brand stage.

    PL/pgSQL enforces the barrier before planning/executing the original SQL.
    The language change is disclosed; owner, ACL, OID, volatility, security and
    function settings stay unchanged and are read back independently.
    """
    opening = re.search(r'\bAS\s+(\$[A-Za-z_0-9]*\$)', original, re.I)
    if not opening:
        raise ValueError('Original SQL brand function body required')
    header, changes = re.subn(r'\bLANGUAGE\s+(?:"sql"|sql)(?=\s)', 'LANGUAGE plpgsql', original[:opening.start()], count=1, flags=re.I)
    if changes!=1:
        raise ValueError('Expected existing SQL-language brand helper')
    body = routine_body(original).rstrip().rstrip(';')
    return header + f"""AS $portal869_brand_barrier$
begin
 perform pg_catalog.pg_advisory_xact_lock(869,{gate});
 return (
{body}
 );
end;
$portal869_brand_barrier$;
"""


def one_facets(c: Collector, label: str) -> dict:
    rows = c.call(label,"begin;set local work_mem='4MB';set local statement_timeout='8s';set local role anon;select jsonb_build_object('readerRole',current_user,'readerPid',pg_backend_pid(),'payload',api.portal_facets_v4(array['bafu','tiangong_lca','uslci','worldsteel'],'all','50-00-0','{}'));rollback;",30)
    if len(rows)!=1 or rows[0]['readerRole']!='anon' or rows[0]['readerPid'] in c.pids.values() or rows[0]['payload'] is None:
        raise ValueError('One independent anonymous complete Facets DTO required')
    return rows[0]


def logical_data(c: Collector, label: str) -> dict:
    rows=c.call(label,'begin;'+upgrade.snapshot_helpers()+"select jsonb_build_object('data',pg_temp.upgrade_snapshot()->'data');rollback;")
    if len(rows)!=1:
        raise ValueError('One complete non-native data digest required')
    return rows[0]['data']


def reader_cutover_run(c: Collector) -> None:
    gate = int(hashlib.sha256(c.nonce.encode()).hexdigest()[:8],16)%2000000000+1
    controller=c.session('reader-controller')
    c.send(controller,'reader-exclusive-fixture',"do $$begin if not pg_try_advisory_lock(864,1) then raise exception 'Another fixture owns this database';end if;end$$;"+marker('READER_OWNED'))
    parse_marker(controller,'READER_OWNED')
    c.call('reader-locked-canonical',canonical_guard(c.predecessor))
    initial=c.call('reader-original-helpers',"select jsonb_build_object('webhook',pg_get_functiondef('util.invoke_edge_function(text,jsonb,integer)'::regprocedure),'brand',pg_get_functiondef('private.portal_display_brand_facets_v1(jsonb,text,text,jsonb)'::regprocedure),'brandMetadata',(select to_jsonb(p)-'prosrc'-'prolang' from pg_proc p where oid='private.portal_display_brand_facets_v1(jsonb,text,text,jsonb)'::regprocedure));")[0]
    c.util_original=initial['webhook']
    c.brand_original=initial['brand']
    seed=upgrade.source_fixture().replace('create extension if not exists pgtap with schema extensions;','')
    c.call('reader-seed-before-a','begin;'+seed+'\ncommit;')
    c.report['fixtureRetained']=c.report['resetRequired']=True
    c.restore_webhook()
    phases_a=c.call('reader-commit-a',"select jsonb_build_object('phase','A','startedEpoch',extract(epoch from clock_timestamp()));"+'begin;'+'\n'.join(c.phases.prepare)+"commit;select jsonb_build_object('phase','A','commitObservedEpoch',extract(epoch from clock_timestamp()),'flowRows',(select count(*) from private.display_navigation_versions_v1 where dataset_kind='flow'),'nonNullCas',(select count(*) from private.display_navigation_versions_v1 where cas_number is not null),'indexPresent',to_regclass('private.d807_portal_navigation_versions_flow_cas_v1_idx') is not null);")
    if len(phases_a)!=2 or phases_a[1]['flowRows']<=0 or phases_a[1]['nonNullCas']!=0 or phases_a[1]['indexPresent']:
        raise ValueError('Reader probe requires real pre-A rows with native CAS NULL after committed A')
    c.report.update({'phaseACommitted':True,'phaseA':phases_a})
    original_reference=one_facets(c,'reader-original-reference')
    wrapped=barrier_brand_definition(c.brand_original,gate)
    installed=c.call('reader-install-brand-barrier','begin;'+wrapped+bench.REFRESH+"select private.portal_display_assert_contract_v1();select jsonb_build_object('brandMetadata',(select to_jsonb(p)-'prosrc'-'prolang' from pg_proc p where oid='private.portal_display_brand_facets_v1(jsonb,text,text,jsonb)'::regprocedure));commit;")
    if len(installed)!=1 or installed[0]['brandMetadata']!=initial['brandMetadata']:
        raise ValueError('Reader barrier changed existing owner/ACL/security/volatility/settings or other metadata')
    wrapper_reference=one_facets(c,'reader-wrapper-pre-b-reference')
    if original_reference['payload']!=wrapper_reference['payload']:
        raise ValueError('Read-only wrapper changed pre-B complete DTO')
    before_data=logical_data(c,'reader-pre-b-logical-data')
    c.report['barrierInstrumentation']={'existingFunction':'private.portal_display_brand_facets_v1(jsonb,text,text,jsonb)',
        'languageChange':'SQL to PL/pgSQL solely to enforce a read-only barrier before the original SQL; no production change',
        'oidOwnerAclSecurityVolatilitySettingsUnchanged':True,'wrapperSha256':bench.sha(wrapped),
        'originalDefinitionSha256':bench.sha(c.brand_original),'preBWrapperEqualsOriginal':True}
    controller.send(f'select pg_advisory_lock(869,{gate});'+marker('BRAND_GATE_OWNED'))
    parse_marker(controller,'BRAND_GATE_OWNED')
    reader=c.session('paused-reader')
    c.send(reader,'one-actual-stable-facets-rpc',"begin;set local transaction_isolation='read committed';set local work_mem='4MB';set local statement_timeout='8s';set local role anon;"+marker('RPC_STARTED')+"select 'RPC_RESULT:'||jsonb_build_object('readerRole',current_user,'readerPid',pg_backend_pid(),'isolation',current_setting('transaction_isolation'),'requestTimeout',current_setting('statement_timeout'),'payload',api.portal_facets_v4(array['bafu','tiangong_lca','uslci','worldsteel'],'all','50-00-0','{}'))::text;reset role;commit;"+marker('RPC_COMPLETED'))
    started=parse_marker(reader,'RPC_STARTED')
    waiting=c.observe('actual-rpc-paused-after-ordinary-facets','paused-reader','reader-controller',False)
    phases_b=c.call('reader-actual-b-commit',"select jsonb_build_object('phase','B','startedEpoch',extract(epoch from clock_timestamp()));"+'begin;'+'\n'.join(c.phases.activate)+"commit;select jsonb_build_object('phase','B','commitObservedEpoch',extract(epoch from clock_timestamp()),'nativeIndexBytes',pg_relation_size('private.d807_portal_navigation_versions_flow_cas_v1_idx'));")
    if len(phases_b)!=2 or phases_b[1]['nativeIndexBytes']<=0:
        raise ValueError('Actual B commit and native index receipt required')
    c.report['phaseBCommitted']=True
    c.report['phaseB']=phases_b
    c.release(controller,'RELEASE_BRAND_GATE',gate)
    paused=parse_marker(reader,'RPC_RESULT',10)
    completed=parse_marker(reader,'RPC_COMPLETED',10)
    if paused['readerRole']!='anon' or paused['readerPid']!=c.pids['paused-reader'] or paused['isolation']!='read committed' or paused['requestTimeout']!='8s':
        raise ValueError('Exact paused anonymous RPC identity required')
    fresh=one_facets(c,'reader-fresh-post-b-reference')
    after_data=logical_data(c,'reader-post-b-logical-data')
    c.call('reader-validate-native-facts',upgrade.native_assert_sql(True))
    same_data=before_data==after_data
    same_reference=wrapper_reference['payload']==fresh['payload']
    same_paused=paused['payload']==wrapper_reference['payload']==fresh['payload']
    c.report['readerCutover']={'ordinaryIsolation':'READ COMMITTED; one actual STABLE API call; no repeatable-read substitute',
        'requestBudget':'8s','requestStartedMarker':started,'observedBrandStageBarrier':waiting,'requestCompletedMarker':completed,
        'observedWallMs':1000*(completed['epoch']-started['epoch']),
        'preBReference':wrapper_reference,'pausedRpc':paused,'freshPostBReference':fresh,
        'nonNativeDataBefore':before_data,'nonNativeDataAfter':after_data,'samePublicAndOldProjectionData':same_data,
        'preBEqualsFreshPostB':same_reference,'pausedEqualsBothReferences':same_paused,
        'classification':'product counterexample: successful in-flight DTO changed across native activation' if same_data and same_reference and not same_paused else 'complete in-flight DTO comparison'}
    if not same_data:
        raise ValueError('Reader-cutover fixture changed public or existing projection data')
    if not same_reference:
        raise ValueError('Fresh native reader differs from pre-B complete DTO on unchanged public data')
    if not same_paused:
        raise ValueError('Product counterexample: successful in-flight Facets DTO differs from both complete pre/post-B references')
    c.report['passed']=True


def cost_sql(predecessor: dict, phases, samples: int) -> str:
    queries = {
        'cas_one': (update_sql(TARGET_ONE,'67-56-1'),1),
        'cas_batch': ("update public.flows set json=jsonb_set(json," + bench.literal(CAS_PATH) + ",'\"67-56-1\"'::jsonb) where version='01.00.000' and id in ('86900000-0000-4000-8000-000000000101','86900000-0000-4000-8000-000000000102','86900000-0000-4000-8000-000000000109') returning id",3),
        'withdraw_batch': ("update private.dataset_display_settings set is_visible=false where dataset_kind='flow' and dataset_id in ('86900000-0000-4000-8000-000000000101','86900000-0000-4000-8000-000000000102','86900000-0000-4000-8000-000000000109') returning dataset_id",4)}
    sql = "begin;set local work_mem='4MB';set local statement_timeout='60s';do $$begin if not pg_try_advisory_xact_lock(864,1) then raise exception 'Another owned fixture is active';end if;end$$;\n"
    sql += canonical_guard(predecessor) + writer_fixture() + upgrade.snapshot_helpers()
    sql += """
create temp table writer_cost(variant text,operation text,ordinal integer,expected_rows integer,plan jsonb,primary key(variant,operation,ordinal));
create temp table phase_epochs(phase text,started timestamptz,ended timestamptz,index_bytes bigint,table_bytes bigint);
create function pg_temp.measure_writer(v text,op text,ord integer,q text,expected_rows integer) returns void language plpgsql as $$
declare before_data jsonb;before_native jsonb;plan jsonb;
begin
 before_data:=pg_temp.upgrade_snapshot()->'data';
 before_native:=pg_temp.upgrade_snapshot()#>'{nativeExtension,facts}';
 begin
  execute 'explain (analyze,buffers,wal,format json) '||q into plan;
  if (plan#>>'{0,Plan,Actual Rows}')::integer is distinct from expected_rows then
   raise exception 'Real writer operation affected unexpected rows';
  end if;
  raise exception using errcode='P0869',message='rollback real writer cost operation';
 exception when sqlstate 'P0869' then
  if sqlerrm<>'rollback real writer cost operation' then raise;end if;
 end;
 if pg_temp.upgrade_snapshot()->'data' is distinct from before_data
  or pg_temp.upgrade_snapshot()#>'{nativeExtension,facts}' is distinct from before_native then
  raise exception 'Real writer cost operation rollback leaked logical data';
 end if;
 insert into writer_cost values(v,op,ord,expected_rows,plan);
end$$;
"""
    for variant in ('baseline','candidate'):
        if variant == 'candidate':
            for name, statements in (('A',phases.prepare),('B',phases.activate)):
                sql += f"insert into phase_epochs(phase,started) values('{name}',clock_timestamp());\n"
                sql += '\n'.join(statements)
                sql += f"\nupdate phase_epochs set ended=clock_timestamp(),index_bytes=coalesce(pg_relation_size(to_regclass('{NATIVE_INDEX}')),0),table_bytes=pg_relation_size('private.display_navigation_versions_v1') where phase='{name}';\n"
            sql += upgrade.native_assert_sql(True)
        for ordinal in range(-1,samples):
            for label,(query,rows) in queries.items():
                sql += f"select pg_temp.measure_writer({bench.literal(variant)},{bench.literal(label)},{ordinal},{bench.literal(query)},{rows});\n"
    sql += upgrade.native_assert_sql(True)
    sql += """select jsonb_build_object('measurements',(select jsonb_agg(to_jsonb(w) order by variant,operation,ordinal) from writer_cost w),
 'phaseEpochs',(select jsonb_agg(to_jsonb(p)||jsonb_build_object('elapsedMs',extract(epoch from ended-started)*1000) order by phase) from phase_epochs p),
 'finalNativeIndexBytes',pg_relation_size('private.d807_portal_navigation_versions_flow_cas_v1_idx'),
 'finalNavigationTableBytes',pg_relation_size('private.display_navigation_versions_v1'));
rollback;
"""
    return sql


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=('reader-cutover','fence','cost'),required=True)
    parser.add_argument('--container',choices=[bench.CONTAINER],required=True)
    parser.add_argument('--base-ref',required=True)
    parser.add_argument('--owner-file',type=Path,choices=[bench.OWNER],default=bench.OWNER)
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--samples',type=int,choices=range(1,6),default=3)
    args = parser.parse_args()
    if not args.report.resolve().is_relative_to(bench.OWNER.parent.resolve()) or any(args.report.with_suffix(suffix).exists() for suffix in ('.json','.sql','.log')) or args.report.suffix!='.json':
        parser.error('New .json/.sql/.log evidence paths in the exact private owner directory are required')
    try:
        base = subprocess.check_output(['git','rev-parse',args.base_ref+'^{commit}'],cwd=upgrade.ROOT,text=True).strip()
        _,source,phases = upgrade.load_candidate(base,None)
        predecessor = bench.baseline(base,list(bench.reader_definitions(source)))
        context = json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
        inspected = json.loads(subprocess.check_output(['docker','inspect',args.container],text=True))[0]
        bench.validate_target(context,inspected,args.owner_file.read_text())
        empty = bench.run(bench.guard_sql(),60)
        if empty.returncode or empty.stdout.strip().splitlines()!=bench.empty_guard_expected():
            raise ValueError('Exact empty owned local PG17.11 target required; CLI reset first')
        admitted = upgrade.visibility_run('portal869-cutover-initial-admission',canonical_guard(predecessor)+upgrade.catalog_query()+';',60)
        if admitted.returncode:
            raise ValueError('Canonical Main 439 initial schema/head proof failed')
        initial = json.loads(admitted.stdout)
    except (OSError,ValueError,subprocess.CalledProcessError,subprocess.TimeoutExpired) as exc:
        parser.error(str(exc))
    args.report.parent.mkdir(parents=True,exist_ok=True)
    c = Collector(args,predecessor,phases,source,context,inspected,initial)
    try:
        if args.mode=='reader-cutover':
            reader_cutover_run(c)
            c.report['classification']='one actual in-flight anonymous STABLE Facets RPC across committed raw-SQL B on pre-A real rows; no ledger transition'
        elif args.mode=='fence':
            fence_run(c)
            c.report['classification']='committed owned-local real-writer lock ordering and complete DTO visibility; raw SQL phase commits, no ledger transition'
        else:
            records = c.call('rollback-only-writer-wal',cost_sql(predecessor,phases,args.samples),300)
            if len(records)!=1:
                raise ValueError('One complete writer WAL result required')
            result = records[0]
            expected = {(v,op,n) for v in ('baseline','candidate') for op in ('cas_one','cas_batch','withdraw_batch') for n in range(-1,args.samples)}
            actual = [(r['variant'],r['operation'],r['ordinal']) for r in result['measurements']]
            if len(actual)!=len(set(actual)) or set(actual)!=expected:
                raise ValueError('Missing/duplicate writer WAL measurements')
            for row in result['measurements']:
                explain = row['plan'][0]
                if any(key not in explain['Plan'] for key in ('WAL Records','WAL FPI','WAL Bytes')) or not explain.get('Triggers'):
                    raise ValueError('EXPLAIN WAL and real trigger execution evidence required')
            c.report.update({'passed':True,'result':result,'samples':args.samples,
                'classification':'rollback-only real writer EXPLAIN ANALYZE/BUFFERS/WAL; fixed baseline-then-candidate order with per-operation warmup; no hosted latency claim',
                'phaseTransactions':'raw A/B statements inside one outer rollback transaction for writer cost only; fence mode qualifies real phase commits',
                'walScope':'EXPLAIN root ModifyTable WAL counters exclude AFTER-trigger navigation writes and test rollback WAL; they do not measure native index write amplification; no global WAL LSN deltas',
                'timingScope':'EXPLAIN total Execution Time includes trigger execution; instrumentation and fixed baseline/candidate order make these diagnostic samples, not throughput or hosted latency'})
    except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired,queue.Empty) as exc:
        c.report['passed']=False
        c.report['failure']=str(exc)
    finally:
        try:
            c.cleanup_sessions()
            rows=c.call('cleanup-receipt',upgrade.catalog_query()+";select jsonb_build_object('nonceSessions',(select count(*) from pg_stat_activity where pid<>pg_backend_pid() and application_name like "+bench.literal(c.prefix+'%')+"),'fixtureExclusiveLockReleased',pg_try_advisory_xact_lock(864,1),'processRows',(select count(*) from public.processes),'flowRows',(select count(*) from public.flows),'settingsRows',(select count(*) from private.dataset_display_settings),'manifestValid',(select identity=private.portal_display_contract_identity_v1() from private.portal_display_contract_manifest where singleton));",30)
            if len(rows)!=2:
                raise ValueError('Complete final metadata and retained-resource receipt required')
            metadata,receipt=rows
            if args.mode=='cost' and metadata!=initial:
                raise ValueError('Rollback-only writer cost left permanent metadata or logical facts changed')
            if receipt['nonceSessions'] or not receipt['fixtureExclusiveLockReleased'] or not receipt['manifestValid'] or metadata['migrationHead']!=CANONICAL_MIGRATION:
                raise ValueError('Owned sessions/locks/manifest or untouched migration ledger cleanup failed')
            retained=bool(receipt['processRows'] or receipt['flowRows'] or receipt['settingsRows'])
            c.report.update({'fixtureRetained':retained,'resetRequired':retained or args.mode=='cost',
                'cleanup':receipt|{'disposition':'retained for exact owned CLI reset' if retained else 'logical fixture rolled back; reset before other qualification because physical pages/statistics may remain',
                    'resetBeforeOtherQualification':True,'containersCreated':0,'volumesCreated':0,'newNativeSchemaRetained':metadata['nativeExtension']['column'] is not None}})
        except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as exc:
            c.report['passed']=False
            c.report['cleanupFailure']=str(exc)
        c.finish_files()
    print(json.dumps({'report':str(args.report),'passed':c.report['passed'],'fixtureRetained':c.report['fixtureRetained'],'resetRequired':c.report['resetRequired'],'failure':c.report.get('failure'),'cleanup':c.report['cleanup']},indent=2))
    return int(not c.report['passed'])


if __name__=='__main__':
    sys.exit(main())
