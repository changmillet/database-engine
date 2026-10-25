#!/usr/bin/env python3
"""Database #864: four-client, committed-fixture scoped reader comparison.

Requires an exact successful serial receipt, the same collector implementation,
source definitions and fixture. Retains synthetic rows for Main's owned reset;
restores candidate readers in finally. Never accepts a DSN or resets a database.
All process output streams to bounded private files. Wall latency includes the
Docker/psql lifecycle; database timestamps and pg_stat_activity prove overlap.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid

import benchmark_portal_facets_navigation as serial

SCOPES = ('tiangong_lca', 'bafu,tiangong_lca,uslci,worldsteel')
CLIENTS = 4
MAX_REFERENCE = 64 * 1024 * 1024
MAX_OUTPUT = 1024 * 1024
MAX_ARTIFACTS = 256 * 1024 * 1024
DEFAULT_CASES = ('facets_all_empty', 'facets_all_geography', 'facets_all_history',
                 'facets_all_one', 'facets_flow_cas', 'navigation_geography',
                 'navigation_us', 'navigation_page3')
ALL_CASES = tuple(sorted(set(serial.cases(SCOPES[0], 'cas-dense')) |
                         {'navigation_page2', 'navigation_page3', 'navigation_cn_page2'}))
INSPECT_FORMAT = '{"Id":{{json .Id}},"Name":{{json .Name}},"Config":{"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}}},"State":{"Running":{{json .State.Running}}},"HostConfig":{"NanoCpus":{{json .HostConfig.NanoCpus}},"CpuQuota":{{json .HostConfig.CpuQuota}},"CpuPeriod":{{json .HostConfig.CpuPeriod}},"CpusetCpus":{{json .HostConfig.CpusetCpus}},"Memory":{{json .HostConfig.Memory}},"MemorySwap":{{json .HostConfig.MemorySwap}}}}'


def bounded_json(path: Path, maximum: int = MAX_REFERENCE):
    if path.stat().st_size > maximum:
        raise ValueError('JSON artifact exceeds bounded input limit')
    return json.loads(path.read_text())


def write_private(path: Path, value: bytes):
    with serial.private_output(path) as output:
        output.write(value)


def serial_rows(report: dict, cases: dict, samples: int) -> dict:
    """Validate complete, stable, successful canonical serial responses."""
    expected = {(v, scope + ':' + name, ordinal)
                for v in ('baseline', 'candidate') for scope in SCOPES
                for name in cases[scope] for ordinal in range(-1, samples)}
    indexed = {}
    for row in report['samples']:
        key = (row['variant'], row['label'], row['ordinal'])
        if key in indexed:
            raise ValueError('Duplicate serial sample')
        indexed[key] = row
        if row['error'] or not isinstance(row.get('canonicalJson'), str):
            raise ValueError('Serial errors/null responses are not reference evidence')
        if serial.sha(row['canonicalJson']) != row['sha256'] or json.loads(row['canonicalJson']) != row['payload']:
            raise ValueError('Serial canonical payload/digest mismatch')
        if (row['sessionRole'], row['workMem'], row['statementTimeout']) != ('anon', '4MB', '8s'):
            raise ValueError('Serial execution principal or budgets differ')
    predecessors = {('baseline', scope+':'+name, -2) for scope in SCOPES for name in ('navigation_world','navigation_page2','navigation_geography')}
    if {key for key in indexed if key[2] < -1} != predecessors:
        raise ValueError('Serial predecessor cursor matrix differs')
    actual = {key for key in indexed if key[2] >= -1}
    if actual != expected:
        raise ValueError('Serial sample matrix is incomplete or unexpected')
    for _, label, ordinal in expected:
        if indexed['baseline', label, ordinal]['canonicalJson'] != indexed['candidate', label, ordinal]['canonicalJson']:
            raise ValueError('Serial predecessor/candidate responses differ')
        reference = indexed['baseline', label, 0]['canonicalJson']
        if indexed['baseline', label, ordinal]['canonicalJson'] != reference:
            raise ValueError('Serial response is unstable across samples')
    return indexed


def validate_reference(report: dict, candidate: str, base: str) -> tuple[dict, dict, dict]:
    if (report.get('schemaVersion') != 'portal.facets-navigation-serial.v1' or
            report.get('passed') is not True or report.get('baselineOnly') is not False or
            report.get('candidateLocalP95TargetPassed') is not True or
            report.get('cleanup', {}).get('emptyRowsAndLocalIdentityVerified') is not True):
        raise ValueError('Complete successful serial correctness/latency/cleanup receipt required')
    if report.get('baseCommit') != base or report.get('candidateSha256') != serial.sha(candidate):
        raise ValueError('Serial receipt does not bind exact baseline/candidate source')
    if report.get('collectorSha256') != serial.file_sha(Path(serial.__file__)):
        raise ValueError('Serial fixture/cases implementation changed; rerun serial reference')
    source_artifact = Path(report['collectorArtifact'])
    if source_artifact.stat().st_size > MAX_OUTPUT or serial.file_sha(source_artifact) != report['collectorSha256']:
        raise ValueError('Serial collector source artifact missing or inconsistent')
    candidate_defs = serial.reader_definitions(candidate)
    variants = {'baseline': serial.definitions_sql(serial.baseline(base, list(candidate_defs))),
                'candidate': serial.definitions_sql(candidate_defs)}
    if report['baselineSourceSha256'] != serial.sha(variants['baseline']) or report['candidateReaderSha256'] != serial.sha(variants['candidate']):
        raise ValueError('Serial reader definition hashes differ')
    fixture = report['fixture']
    p, f, padding = fixture['processVersions'], fixture['flowVersions'], fixture['summaryPaddingBytes']
    profile = fixture.get('profile')
    native = fixture.get('nativeCasFact')
    if profile not in serial.FIXTURE_PROFILES:
        raise ValueError('Explicit supported fixture profile required')
    if not (type(p) is int and type(f) is int and p % 2 == f % 2 == 0 and
            40 <= p <= 40000 and 80 <= f <= 200000 and type(padding) is int and 0 <= padding <= 4096):
        raise ValueError('Serial fixture parameters are outside guarded bounds')
    if fixture != serial.fixture_metadata(p//2, f//2, padding, profile, native):
        raise ValueError('Serial fixture profile metadata differs')
    samples = max(row['ordinal'] for row in report['samples']) + 1
    if not 2 <= samples <= 20:
        raise ValueError('Serial sample count is outside supported bounds')
    selected = report['selectedCases']
    if selected == 'full matrix':
        selected = None
    elif not isinstance(selected, list) or not selected or not set(selected).issubset(ALL_CASES):
        raise ValueError('Unsupported serial case matrix')
    sql, cases = serial.build_sql(variants, p // 2, f // 2, padding, samples, SCOPES,
                                 selected_cases=selected, plan_min_ms=report['nestedPlanMinDurationMs'], fixture_profile=profile, native_cas_fact=native)
    if serial.sha(sql) != report['sqlSha256']:
        raise ValueError('Serial SQL/fixture/cursor identity cannot be reconstructed')
    indexed = serial_rows(report, cases, samples)
    actual = report['fixtureActual']
    if actual['processVersions'] != p or actual['flowVersions'] != f or actual['publicSourceRows'] != 0:
        raise ValueError('Serial actual fixture cardinality differs')
    if profile == 'cas-dense' and actual.get('casCounts') != serial.expected_dense_cas_counts(f//2):
        raise ValueError('Serial dense CAS distribution/invariant differs')
    if native:
        for snapshot in (report.get('nativeSchemaBefore'),report.get('nativeSchema')):
            if not isinstance(snapshot,dict) or serial.validate_native_schema(snapshot) != report.get('nativeSchemaFingerprint'):
                raise ValueError('Serial native schema fingerprint differs')
        expected = serial.expected_dense_cas_counts(f//2)
        if actual.get('nativeCasFact') != {k:expected[k] for k in ('nonNull','rare','common')} | {'mismatches':0}:
            raise ValueError('Serial native fact differs from original CAS predicate')
        _, failures = serial.native_plan_gate(report.get('nestedPlanCoverage',{}).get('groups',[]),SCOPES)
        if failures: raise ValueError('Serial native natural plan proof incomplete')
    if not report.get('equivalence') or any(item.get('equal') is not True for item in report['equivalence']):
        raise ValueError('Serial equivalence proof is incomplete')
    return variants, cases, indexed


def request_cases(cases: dict, indexed: dict, selected: tuple[str, ...]) -> dict:
    result = {}
    for scope in SCOPES:
        for name in selected:
            if name not in cases[scope]:
                raise ValueError('Selected concurrent case missing in serial receipt: ' + name)
            statement = cases[scope][name]
            def cursor(match):
                label = match[1].replace("''", "'")
                row = indexed.get(('baseline', label, -2))
                value = row['payload'].get('nextCursor') if row else None
                if not isinstance(value, str) or not value:
                    raise ValueError('Actual predecessor cursor missing: ' + label)
                return serial.literal(value)
            statement = re.sub(r"pg_temp\.predecessor_cursor\('((?:[^']|'')*)'\)", cursor, statement)
            if 'pg_temp.' in statement:
                raise ValueError('Cross-session temporary cursor dependency remains')
            result[scope + ':' + name] = statement
    return result


def fixture_summary_sql(native_cas_fact: bool = False) -> str:
    return serial.fixture_summary_sql(native_cas_fact)


def client_sql(application: str, statement: str) -> str:
    # Exact one-call payload materialization. The measurement interval excludes
    # collector setup; the separate Python wall timer includes Docker/psql.
    return f"""set application_name={serial.literal(application)};
begin;
set local statement_timeout='8s';set local work_mem='4MB';
create function pg_temp.portal864_measure() returns jsonb language plpgsql as $$
declare started timestamptz;finished timestamptz;payload jsonb;failure text;begin
 started:=clock_timestamp();
 begin execute {serial.literal(statement)} into payload;
 exception when query_canceled then failure:=sqlstate;when others then failure:=sqlstate;end;
 finished:=clock_timestamp();
 return jsonb_build_object('pid',pg_backend_pid(),'startedEpoch',extract(epoch from started),
 'finishedEpoch',extract(epoch from finished),'canonicalJson',payload::text,
 'sha256',encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex'),
 'error',failure,'sessionRole',current_user,'workMem',current_setting('work_mem'),
 'statementTimeout',current_setting('statement_timeout'));
end$$;
grant execute on function pg_temp.portal864_measure() to anon;
set local role anon;
select pg_temp.portal864_measure();
rollback;
"""


def execute_file(sql_path: Path, output_path: Path, log_path: Path, application: str,
                 timeout: int, stop: threading.Event | None = None) -> tuple[int, float]:
    command = ['docker', 'exec', '-i', serial.CONTAINER, 'psql', '-X', '-h',
               '/var/run/postgresql', '-U', 'supabase_admin', '-d', 'postgres',
               '-Atq', '-v', 'ON_ERROR_STOP=1']
    process = None
    began = time.perf_counter()
    try:
        with sql_path.open('rb') as source, serial.private_output(output_path) as output, serial.private_output(log_path) as log:
            process = subprocess.Popen(command, stdin=source, stdout=output, stderr=log)
            while process.poll() is None:
                if stop is not None and stop.is_set():
                    raise RuntimeError('Peer request cancelled')
                if output_path.stat().st_size > MAX_OUTPUT or log_path.stat().st_size > MAX_OUTPUT:
                    raise RuntimeError('Request output exceeds private artifact bound')
                if time.perf_counter() - began > timeout:
                    raise RuntimeError('Request process deadline exceeded')
                try:
                    process.wait(timeout=.05)
                except subprocess.TimeoutExpired:
                    pass
        if max(output_path.stat().st_size, log_path.stat().st_size) > MAX_OUTPUT:
            raise RuntimeError('Request output exceeds private artifact bound')
        return process.returncode, (time.perf_counter() - began)*1000
    except BaseException:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        serial.run('select pg_cancel_backend(pid) from pg_stat_activity where application_name=' + serial.literal(application) + ' and pid<>pg_backend_pid();', 30)
        raise


def json_output(path: Path) -> dict:
    if path.stat().st_size > MAX_OUTPUT:
        raise ValueError('Response exceeds bounded input limit')
    values = [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
    if len(values) != 1:
        raise ValueError('Unique complete JSON response required')
    return values[0]


def maximum_overlap(rows: list[dict]) -> int:
    events = [(row[key], delta) for row in rows if row.get('startedEpoch') is not None
              for key, delta in (('startedEpoch', 1), ('finishedEpoch', -1))]
    current = maximum = 0
    for _, delta in sorted(events):
        current += delta
        maximum = max(maximum, current)
    return maximum


def summarize(rows: list[dict], selected: dict, rounds: int, observed: dict) -> tuple[dict, list[str]]:
    failures = []
    expected = {(variant, label, ordinal, client) for variant in ('baseline', 'candidate')
                for label in selected for ordinal in range(rounds) for client in range(CLIENTS)}
    keys = [(r['variant'], r['label'], r['ordinal'], r['client']) for r in rows]
    if len(keys) != len(set(keys)) or set(keys) != expected:
        failures.append('Missing/duplicate concurrent request matrix')
    for row in rows:
        if (row['variant'] == 'candidate' and row.get('error')) or (not row.get('error') and row.get('matchesSerial') is not True):
            failures.append(f"{row['variant']} {row['label']} {row['ordinal']}/{row['client']}: {row.get('error') or 'response differs'}")
    timings = {}
    for variant in ('baseline', 'candidate'):
        for label in selected:
            values = sorted(r['wallMs'] for r in rows if r['variant'] == variant and r['label'] == label and not r.get('error'))
            p95 = values[math.ceil(len(values)*.95)-1] if values else None
            timings[variant + ':' + label] = {'successfulSamples': len(values), 'p95WallMs': p95,
                                             'targetMs': 2000, 'expectedSamples': CLIENTS*rounds, 'meetsTarget': p95 is not None and p95 <= 2000 and len(values)==CLIENTS*rounds}
            if variant == 'candidate' and not timings[variant + ':' + label]['meetsTarget']:
                failures.append('Candidate p95 wall exceeds 2000ms: ' + label)
    overlap = {}
    for variant in ('baseline', 'candidate'):
        records = [r for r in rows if r['variant'] == variant and r.get('pid') and r.get('startedEpoch') is not None]
        overlap[variant] = {'maximumDatabaseIntervalOverlap': maximum_overlap(records),
                            'maximumObservedActiveClients': observed.get(variant, 0),
                            'distinctBackendPids': len({r['pid'] for r in records if r.get('pid')})}
        if overlap[variant]['maximumDatabaseIntervalOverlap'] != CLIENTS or overlap[variant]['maximumObservedActiveClients'] < 2 or overlap[variant]['distinctBackendPids'] < CLIENTS:
            failures.append('Four-client concurrency/observed overlap proof incomplete: ' + variant)
    return {'timings': timings, 'overlap': overlap,
            'baselineErrors': [r for r in rows if r['variant']=='baseline' and r.get('error')],
            'candidateLocalP95TargetPassed': all(v['meetsTarget'] for k,v in timings.items() if k.startswith('candidate:'))}, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True, choices=[serial.CONTAINER])
    parser.add_argument('--reference-report', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--base-ref', required=True)
    parser.add_argument('--native-cas-fact', action='store_true', help='Require the serial receipt native CAS profile and the same installed physical schema')
    parser.add_argument('--owner-file', type=Path, default=serial.OWNER, choices=[serial.OWNER])
    parser.add_argument('--case', dest='selected', action='append', choices=ALL_CASES, metavar='CASE')
    parser.add_argument('--rounds', type=serial.bounded_int(1, 10), default=3, metavar='1..10')
    parser.add_argument('--clients', type=int, default=4, choices=[4])
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    directory = args.report.with_suffix('.artifacts')
    if args.report.exists() or directory.exists() or args.report == args.reference_report:
        parser.error('Report and private artifact directory must be new')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    directory.mkdir(mode=0o700)
    nonce = uuid.uuid4().hex[:12]
    prefix = 'portal864-concurrent-' + nonce
    report = {'schemaVersion': 'portal.facets-navigation-concurrent.v1', 'passed': False,
              'classification': 'owned local synthetic four-client wall profile; not hosted p95',
              'clients': CLIENTS, 'roundsPerCasePerVariant': args.rounds,
              'candidateLocalP95TargetMs': 2000, 'sessionWorkMem': '4MB', 'requestBudget': '8s',
              'applicationPrefix': prefix, 'artifacts': str(directory), 'samples': [],
              'collectorSha256': serial.file_sha(Path(__file__)), 'serialCollectorSha256': serial.file_sha(Path(serial.__file__)),
              'disposition': {'candidateRestored': False, 'syntheticRowsRetained': False,
                              'resetRequired': True, 'resetOwner': 'Main agent; exact owned portal-facets-864 stack'}}
    admitted = seeded = False
    stop = threading.Event()
    expected_identity = None
    variants = None
    native = False
    sequence = 0
    def admin(source: str, label: str, timeout: int = 180) -> dict | None:
        nonlocal sequence
        sequence += 1
        stem = directory / f'admin-{sequence:03d}-{label}'
        application = prefix + '-admin'
        source = 'set application_name=' + serial.literal(application) + ';\n' + source
        write_private(stem.with_suffix('.sql'), source.encode())
        code, _ = execute_file(stem.with_suffix('.sql'), stem.with_suffix('.stdout'), stem.with_suffix('.log'), application, timeout)
        if code:
            raise RuntimeError('Administrative phase failed: ' + label)
        text = stem.with_suffix('.stdout').read_text()
        return json_output(stem.with_suffix('.stdout')) if any(line.startswith('{') for line in text.splitlines()) else None
    try:
        write_private(directory/'collector.py', Path(__file__).read_bytes())
        reference = bounded_json(args.reference_report)
        if reference.get('fixture',{}).get('nativeCasFact') is not args.native_cas_fact:
            raise ValueError('--native-cas-fact must match the exact serial receipt')
        candidate = args.candidate.read_text() if args.candidate.stat().st_size <= MAX_OUTPUT else None
        if candidate is None:
            raise ValueError('Candidate source exceeds bounded input limit')
        base = subprocess.check_output(['git', 'rev-parse', f'{args.base_ref}^{{commit}}'], cwd=serial.ROOT, text=True).strip()
        variants, cases, indexed = validate_reference(reference, candidate, base)
        selected = tuple(args.selected or DEFAULT_CASES)
        if len(selected) != len(set(selected)):
            raise ValueError('Duplicate selected case')
        requests = request_cases(cases, indexed, selected)
        context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
        inspected = json.loads(subprocess.check_output(['docker', 'inspect', '--format', INSPECT_FORMAT, serial.CONTAINER], text=True))
        owner = args.owner_file.read_text()
        serial.validate_target(context, inspected, owner)
        if inspected['Config']['Image'] != reference['image'] or inspected['HostConfig'] != reference['resources']:
            raise ValueError('Runtime image/resource limits differ from the serial reference')
        check = serial.run(serial.guard_sql()+"select count(*) from pg_stat_activity where application_name like 'portal864-concurrent-%' and pid<>pg_backend_pid();", 60)
        if check.returncode or check.stdout.strip().splitlines() != serial.empty_guard_expected()+['0']:
            raise ValueError('Exact owned empty local prestate required; reset is Main-owned')
        native = reference['fixture']['nativeCasFact']
        native_schema = None
        if native:
            checked_schema = serial.run(serial.native_schema_sql(),60)
            if checked_schema.returncode:
                raise ValueError('Native CAS schema admission query failed')
            native_schema = json.loads(checked_schema.stdout)
            if serial.validate_native_schema(native_schema) != reference['nativeSchemaFingerprint']:
                raise ValueError('Native CAS physical schema differs from serial reference')
        admitted = True
        report.update({'baseCommit': base, 'candidateSha256': serial.sha(candidate),
                       'candidateReaderSha256': serial.sha(variants['candidate']), 'baselineSourceSha256': serial.sha(variants['baseline']),
                       'referenceReport': str(args.reference_report), 'referenceReportSha256': serial.file_sha(args.reference_report),
                       'referenceSqlSha256': reference['sqlSha256'], 'referenceClassification': reference['classification'], 'fixture': reference['fixture'],
                       'containerId': inspected['Id'], 'image': inspected['Config']['Image'],
                       'resources': inspected['HostConfig'], 'dockerContext': context['Name'],
                       'ownerSha256': serial.sha(owner), 'selectedCases': selected,
                       'serialVariantRoutineSettings': reference.get('variantRoutineSettings'),
                       'nativeSchemaBefore':native_schema,'nativeSchemaFingerprint':reference.get('nativeSchemaFingerprint'),
                       'physicalSchemaComparison':reference.get('physicalSchemaComparison'),
                       'functionOverrides': 'Retained exactly from the verified serial definitions; no per-function override is changed by the collector'})
        fixture = reference['fixture']
        seed = serial.fixture(fixture['processVersions']//2, fixture['flowVersions']//2, fixture['summaryPaddingBytes'], fixture['profile'], native)
        seed = seed.replace("set application_name='portal864-serial';", 'set application_name='+serial.literal(prefix+'-admin')+';')
        actual = admin(seed+'\ncommit;\n'+fixture_summary_sql(native), 'seed', 900)
        seeded = True
        report['fixtureActual'] = actual
        if actual != reference['fixtureActual']:
            raise ValueError('Committed actual fixture does not equal serial fixture identity')
        observed = {'baseline': 0, 'candidate': 0}
        for variant in ('baseline', 'candidate'):
            identity = admin("begin;set local lock_timeout='5s';"+variants[variant]+"commit;select jsonb_build_object('identity',private.portal_display_contract_identity_v1());", variant+'-readers')
            report.setdefault('variantIdentities', {})[variant] = identity['identity']
            if variant == 'candidate':
                expected_identity = identity['identity']
            for label, statement in requests.items():
                for ordinal in range(args.rounds):
                    barrier = threading.Barrier(CLIENTS)
                    def one(client: int) -> dict:
                        stem = directory / f'{variant}-{list(requests).index(label):03d}-{ordinal:02d}-{client}'
                        application = prefix+'-'+variant+'-'+str(client)
                        sql = client_sql(application, statement)
                        write_private(stem.with_suffix('.sql'), sql.encode())
                        row = {'variant': variant, 'label': label, 'ordinal': ordinal, 'client': client,
                               'applicationName': application, 'matchesSerial': False,
                               'stdoutArtifact': str(stem.with_suffix('.stdout')), 'logArtifact': str(stem.with_suffix('.log'))}
                        try:
                            barrier.wait(timeout=15)
                            code, wall = execute_file(stem.with_suffix('.sql'), stem.with_suffix('.stdout'), stem.with_suffix('.log'), application, 20, stop)
                            row['wallMs'] = wall
                            if code:
                                row['error'] = 'psql_exit_'+str(code)
                                return row
                            payload = json_output(stem.with_suffix('.stdout'))
                            canonical = payload.pop('canonicalJson', None)
                            row.update(payload)
                            if (row.get('sessionRole'), row.get('workMem'), row.get('statementTimeout')) != ('anon','4MB','8s'):
                                row['error'] = 'role_or_budget_drift'
                            reference_row = indexed[variant, label, 0]
                            row['matchesSerial'] = canonical == reference_row['canonicalJson'] and row.get('sha256') == reference_row['sha256'] and isinstance(canonical,str) and serial.sha(canonical) == row['sha256']
                            row['stdoutSha256'] = serial.file_sha(stem.with_suffix('.stdout'))
                            return row
                        except Exception as exc:
                            stop.set()
                            row['error'] = type(exc).__name__+': '+str(exc)
                            row.setdefault('wallMs', None)
                            return row
                    with ThreadPoolExecutor(max_workers=CLIENTS) as pool:
                        futures = [pool.submit(one, client) for client in range(CLIENTS)]
                        while not all(future.done() for future in futures):
                            query = "select count(*) from pg_stat_activity where application_name like "+serial.literal(prefix+'-'+variant+'-%')+" and state='active' and query like 'select pg_temp.portal864_measure%';"
                            seen = serial.run(query, 10)
                            if seen.returncode or not seen.stdout.strip().isdigit():
                                stop.set()
                                raise RuntimeError('pg_stat_activity overlap observation failed')
                            observed[variant] = max(observed[variant], int(seen.stdout.strip()))
                            time.sleep(.025)
                        report['samples'].extend(future.result() for future in futures)
                    if stop.is_set():
                        raise RuntimeError('Concurrent request batch failed')
                    if sum(path.stat().st_size for path in directory.iterdir() if path.is_file()) > MAX_ARTIFACTS:
                        raise RuntimeError('Total private artifact bound exceeded')
        summary, failures = summarize(report['samples'], requests, args.rounds, observed)
        report.update(summary)
        if native:
            report['relativeCasPerformance'], relative_failures = serial.relative_cas_evidence(report['timings'],list(requests),metric='p95WallMs',enforce='smoke' not in reference['classification'])
            failures.extend(relative_failures)
        report['failures'] = failures
        report['passed'] = not failures
    except BaseException as exc:
        report['failure'] = type(exc).__name__+': '+str(exc)
        report['passed'] = False
        if isinstance(exc, KeyboardInterrupt):
            stop.set()
            raise
    finally:
        stop.set()
        if admitted and variants is not None:
            try:
                restored = admin("begin;set local lock_timeout='5s';"+variants['candidate']+"commit;select jsonb_build_object('identity',private.portal_display_contract_identity_v1());", 'restore-candidate')
                report['disposition']['candidateRestored'] = expected_identity is None or restored['identity'] == expected_identity
                report['restoredCandidateIdentity'] = restored['identity']
                remaining = serial.run("select count(*) from pg_stat_activity where application_name like "+serial.literal(prefix+'%')+" and pid<>pg_backend_pid();", 30)
                report['disposition']['activeClientsRemaining'] = int(remaining.stdout.strip()) if remaining.returncode == 0 and remaining.stdout.strip().isdigit() else None
                report['disposition']['fixtureAfter'] = admin(fixture_summary_sql(native), 'retained-fixture')
                if native:
                    snapshot = admin(serial.native_schema_sql(),'native-schema-final')
                    report['nativeSchema'] = snapshot
                    if serial.validate_native_schema(snapshot) != reference['nativeSchemaFingerprint']:
                        raise ValueError('Native CAS schema changed during concurrent comparison')
                report['disposition']['syntheticRowsRetained'] = bool(report['disposition']['fixtureAfter']['processVersions'] or report['disposition']['fixtureAfter']['flowVersions'])
            except Exception as exc:
                report['disposition']['restoreError'] = type(exc).__name__+': '+str(exc)
            if not report['disposition']['candidateRestored'] or report['disposition'].get('activeClientsRemaining') != 0:
                report['passed'] = False
        write_private(args.report, (json.dumps(report, indent=2)+'\n').encode())
    print(json.dumps({'report':str(args.report),'passed':report['passed'],'failure':report.get('failure'),
                      'failures':report.get('failures'),'candidateLocalP95TargetPassed':report.get('candidateLocalP95TargetPassed'),
                      'disposition':report['disposition']}, indent=2))
    return int(not report['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
