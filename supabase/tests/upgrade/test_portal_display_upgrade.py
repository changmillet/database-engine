#!/usr/bin/env python3
"""Destructive only to the explicitly named disposable #807 local stack."""
import json
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[3]
WORKDIR = '/private/tmp/lca-portal-807-20261010'
CONTAINER = 'supabase_db_portal-display-807-1010'


def sql(source):
    result = subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At'], input=source, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def main():
    owner = Path(WORKDIR, 'ownership.txt').read_text()
    if 'tiangong-lca/database#807' not in owner:
        raise RuntimeError('Task ownership receipt required')
    subprocess.run(['supabase', 'db', 'reset', '--workdir', WORKDIR, '--local', '--no-seed', '--version', '20261010085824'], check=True)
    fixture = (REPO / 'supabase/tests/20261010_portal_display_readers.sql').read_text().split('select is((select count(*)::integer from private.display_catalog_search_rows_v2)')[0]
    sql(fixture + '\ncommit;')
    before = sql("""create table private.portal_807_upgrade_before as
      select p.oid,p.prosrc,p.proowner,p.proacl,p.proconfig,p.prosecdef,p.provolatile,p.proparallel,
      n.nspname,p.proname,oidvectortypes(p.proargtypes) arguments
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname in ('api','private') and (p.proname like '%portal%' or p.proname like '%dataset_display%');
      create table private.portal_807_data_before as select
      (select jsonb_agg(to_jsonb(s) order by dataset_kind,dataset_id,dataset_version) from private.dataset_display_settings s) settings,
      (select jsonb_agg(to_jsonb(p) order by id,version) from public.processes p) processes,
      (select jsonb_agg(to_jsonb(f) order by id,version) from public.flows f) flows;
      create table private.portal_807_acl_before as select jsonb_agg(to_jsonb(m) order by m.grantor) grants
      from pg_auth_members m where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole;
      select count(*) from private.portal_807_upgrade_before;""")
    sql((REPO / 'supabase/migrations/20261010110000_portal_display_projection.sql').read_text())
    proof = sql("""do $$begin
      if exists(select 1 from private.portal_807_upgrade_before b join pg_proc p using(oid)
        where b.proowner<>p.proowner or b.proacl is distinct from case when b.nspname='private' and b.proname in ('portal_brand_v1','portal_dataset_is_visible_v1') then array_remove(p.proacl,'portal_display_executor=X/postgres'::aclitem) else p.proacl end or b.proconfig is distinct from p.proconfig
        or b.prosecdef<>p.prosecdef or b.provolatile<>p.provolatile or b.proparallel<>p.proparallel
        or b.prosrc is distinct from case when b.nspname='api' and b.proname like 'portal_%' then
          (select x.prosrc from pg_proc x where x.oid=to_regprocedure(format('private.display_legacy_%s(%s)',substring(b.proname from 8),b.arguments)))
          else p.prosrc end) then raise exception 'legacy routine identity, metadata, ACL or retained body changed'; end if;
      if exists(select 1 from private.portal_807_data_before b where
        b.settings is distinct from (select jsonb_agg(to_jsonb(s) order by dataset_kind,dataset_id,dataset_version) from private.dataset_display_settings s)
        or b.processes is distinct from (select jsonb_agg(to_jsonb(p) order by id,version) from public.processes p)
        or b.flows is distinct from (select jsonb_agg(to_jsonb(f) order by id,version) from public.flows f)) then raise exception 'source or business settings mutated'; end if;
      if (select grants from private.portal_807_acl_before) is distinct from
        (select jsonb_agg(to_jsonb(m) order by m.grantor) from pg_auth_members m where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole)
        then raise exception 'existing owner membership changed'; end if;
      if (select mode from private.portal_display_rollout) <> 'legacy' or exists(select 1 from private.display_catalog_search_rows_v1)
        then raise exception 'migration activated or backfilled data'; end if;
      end $$;
      select private.portal_display_repair_batch_v1(null,1000);
      select private.portal_display_transition_v1('legacy','display');
      set role anon;
      select api.portal_get_dataset_v2(array['tiangong_lca'],'process','80700000-0000-4000-8000-000000000101','01.00.000')#>>'{brand,code}';
      reset role;""")
    if 'tiangong_lca' not in proof:
        raise RuntimeError('Populated display read failed')
    print(json.dumps({'result':'PASS','retained_routines':before.splitlines()[-1], 'source_and_settings_unchanged':True,'legacy_owner_grants_unchanged':True,'migration_mode':'legacy','operator_repair_and_transition':'PASS'}))


if __name__ == '__main__':
    main()
