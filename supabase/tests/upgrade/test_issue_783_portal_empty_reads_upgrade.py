#!/usr/bin/env python3
"""Verify #783 migration DDL permissions restore prestate on the reused local stack."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
CONTAINER = 'supabase_db_database-engine-777-pg1711'
MIGRATION = ROOT / 'supabase/migrations/20261006074505_portal_empty_navigation_facets_reads.sql'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True)
    parser.add_argument('--reuse-campaign', choices=('workspace-1701',), required=True)
    args = parser.parse_args()
    if args.container != CONTAINER:
        parser.error('Only the explicitly reused campaign PostgreSQL17.11 stack is admitted')
    context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):
        parser.error('Only local Unix Docker is admitted')
    command = ['docker', 'exec', '-i', args.container, 'psql', '-h', '/var/run/postgresql',
               '-U', 'postgres', '-d', 'postgres', '-Atq', '-v', 'ON_ERROR_STOP=1']
    guard = subprocess.run(command, input="select inet_server_addr() is null; select current_setting('server_version'); select count(*) from private.portal_navigation_versions_v1; select count(*) from private.portal_catalog_facet_rows_v1;", text=True, capture_output=True)
    if guard.returncode or guard.stdout.strip().splitlines() != ['t', '17.11', '0', '0']:
        parser.error('Refusing unknown, wrong-version or nonempty target')
    migration = MIGRATION.read_text()
    if migration.count('\nbegin;\n') != 1 or not migration.endswith('commit;\n'):
        raise ValueError('Expected one explicit migration transaction')
    # Retain a single test-owned rollback transaction: no migration commit can
    # persist the synthetic prestate or test DDL permissions.
    body = migration.replace('\nbegin;\n', '\n', 1).removesuffix('commit;\n')
    for label, setup in (
        ('absent', 'revoke portal_public_executor from postgres; revoke create on schema private from portal_public_executor;'),
        ('existing-set-false', 'grant portal_public_executor to postgres with admin false, inherit false, set false; revoke create on schema private from portal_public_executor;'),
        ('existing-create', 'grant portal_public_executor to postgres with admin false, inherit true, set true; grant create on schema private to portal_public_executor;'),
    ):
        sql = 'begin;\n' + setup + """
create temp table issue783_ddl_prestate as
select (select jsonb_agg(to_jsonb(m) order by m.grantor) from pg_auth_members m where roleid='portal_public_executor'::regrole and member='postgres'::regrole) as membership,
       (select to_jsonb(nspacl) from pg_namespace where nspname='private') as schema_acl;
create temp table issue783_function_prestate as
select oid,proowner,proacl,proconfig,prosecdef,provolatile,proparallel from pg_proc
where oid in('private.portal_navigation_impl_v1(text,text,jsonb,text,text,text,integer,text)'::regprocedure,
             'private.catalog_portal_facets_empty_v2_impl(text,text)'::regprocedure);
""" + body + """
do $$begin
 if exists(select 1 from issue783_ddl_prestate b where
   b.membership is distinct from (select jsonb_agg(to_jsonb(m) order by m.grantor) from pg_auth_members m where roleid='portal_public_executor'::regrole and member='postgres'::regrole)
   or b.schema_acl is distinct from (select to_jsonb(nspacl) from pg_namespace where nspname='private')) then
  raise exception 'Database #783 DDL privilege prestate changed';
 end if;
 if exists(select 1 from issue783_function_prestate b join pg_proc p using(oid) where
   (b.proowner,b.proacl,b.proconfig,b.prosecdef,b.provolatile,b.proparallel)
   is distinct from (p.proowner,p.proacl,p.proconfig,p.prosecdef,p.provolatile,p.proparallel)) then
  raise exception 'Database #783 function contract changed';
 end if;
end $$;
rollback;
"""
        result = subprocess.run(command, input=sql, text=True, capture_output=True)
        if result.returncode:
            print(label + ': ' + result.stderr, file=sys.stderr)
            return result.returncode
        print(label + ': DDL membership/schema ACL and function metadata preserved; rolled back')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
