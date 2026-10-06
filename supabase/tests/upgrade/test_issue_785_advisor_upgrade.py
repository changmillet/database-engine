#!/usr/bin/env python3
"""Actual #785 forward-migration rollback and privilege-prestate qualification."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
CONTAINER = 'supabase_db_database-engine-777-pg1711'


def run(sql: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-h',
        '/var/run/postgresql', '-U', 'postgres', '-d', 'postgres', '-Atq',
        '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=sqlstate'],
        input=sql, text=True, capture_output=True, timeout=120)


def body(suffix: str) -> str:
    paths = list((ROOT / 'supabase/migrations').glob('*_' + suffix + '.sql'))
    if len(paths) != 1:
        raise ValueError('Expected one exact migration for ' + suffix)
    sql = paths[0].read_text()
    if sql.count('\nbegin;\n') != 1 or not sql.endswith('commit;\n'):
        raise ValueError('Expected one explicit migration transaction')
    return sql.replace('\nbegin;\n', '\n', 1).removesuffix('commit;\n')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True, choices=(CONTAINER,))
    parser.add_argument('--reuse-campaign', required=True, choices=('workspace-1701',))
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    if args.report.exists():
        parser.error('Report must be new')
    context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):
        parser.error('Only local Unix Docker is admitted')
    guard = """
select inet_server_addr() is null;
select current_setting('server_version');
select count(*) from private.portal_navigation_versions_v1;
select count(*) from public.sources;
select md5(jsonb_build_object(
 'functions',(select jsonb_agg(to_jsonb(p) order by p.oid) from pg_proc p
   where p.pronamespace in('private'::regnamespace,'util'::regnamespace)),
 'policies',(select jsonb_agg(to_jsonb(p) order by p.oid) from pg_policy p),
 'membership',(select jsonb_agg(to_jsonb(m) order by roleid,member,grantor) from pg_auth_members m),
 'schemaAcl',(select jsonb_agg(jsonb_build_array(nspname,nspacl) order by nspname) from pg_namespace
   where nspname in('private','util')))::text);
"""
    check = run(guard)
    expected = check.stdout.strip().splitlines()
    if check.returncode or len(expected) != 5 or expected[:4] != ['t', '17.11', '0', '0']:
        parser.error('Refusing unknown, wrong-version or populated target')
    invokers = body('advisor_invoker_paths')
    policies = body('advisor_authenticated_select_policies')
    retention = body('advisor_preexisting_retention_acl_drift')
    membership = """
create temp table issue785_ddl_before as
select (select jsonb_agg(to_jsonb(m) order by grantor) from pg_auth_members m
 where roleid='portal_public_executor'::regrole and member='postgres'::regrole) membership,
 (select to_jsonb(nspacl) from pg_namespace where nspname='private') schema_acl;
"""
    verify_membership = """
do $$begin
 if exists(select 1 from issue785_ddl_before b where
  b.membership is distinct from (select jsonb_agg(to_jsonb(m) order by grantor) from pg_auth_members m
   where roleid='portal_public_executor'::regrole and member='postgres'::regrole)
  or b.schema_acl is distinct from (select to_jsonb(nspacl) from pg_namespace where nspname='private')) then
  raise exception using errcode='P7851',message='DDL privilege prestate changed';
 end if;
end $$;
"""
    cases = []
    for label, setup in (
        ('absent', 'revoke portal_public_executor from postgres;'),
        ('set-false', 'grant portal_public_executor to postgres with admin false, inherit false, set false;'),
        ('set-true', 'grant portal_public_executor to postgres with admin false, inherit true, set true;'),
    ):
        cases.append(('invoker-' + label, setup + membership + invokers + verify_membership, 0))
    cases += [
        ('invoker-public-acl-refused', 'grant execute on function private.dataset_alias_v2_multiply_amount(text,text) to public;\n' + invokers, 3),
        ('policy-canonical-replay', policies, 0),
        ('policy-unknown-predicate-refused', 'alter policy "Enable read access for authenticated users" on public.sources using(true);\n' + policies, 3),
        ('retention-canonical-replay', retention, 0),
        ('retention-production-replay', (ROOT / 'supabase/tests/fixtures/20261006_advisor_retention_production.sql').read_text() + retention, 0),
        ('retention-unknown-body-refused', "create or replace function util.purge_supabase_functions_hooks(p_retention_window interval default '14 days',p_batch_size integer default 50000) returns bigint language plpgsql set search_path='' as $$begin return -1;end$$;\n" + retention, 3),
        ('binding-browser-acl-refused', 'grant execute on function private.lcia_scope_closure_bundle_binding_matches(private.lcia_scope_closure_checks,private.worker_job_artifacts) to authenticated;\n' + retention, 3),
    ]
    results = []
    for label, sql, expected_code in cases:
        result = run('begin;\n' + sql + '\nrollback;\n')
        passed = result.returncode == expected_code and (expected_code == 0 or '55000' in result.stderr)
        results.append({'case': label, 'passed': passed, 'exitCode': result.returncode})
        cleanup = run(guard)
        if cleanup.returncode or cleanup.stdout.strip().splitlines() != expected:
            raise RuntimeError('Rollback fixture/version guard failed')
        if not passed:
            print(label + ': failed; ' + result.stderr[-1000:])
            break
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({'container': CONTAINER, 'results': results,
        'rollbackFixtures': True, 'scope': 'local17.11 deployment-postgres DDL proof; not hosted qualification'}, indent=2) + '\n')
    print(json.dumps({'report': str(args.report), 'results': results}, indent=2))
    return int(len(results) != len(cases) or any(not x['passed'] for x in results))


if __name__ == '__main__':
    raise SystemExit(main())
