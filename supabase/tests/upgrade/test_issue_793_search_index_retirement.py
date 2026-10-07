#!/usr/bin/env python3
"""Database #793 rollback-only refusal, membership, replay and domain qualification.

Run on the exact task-owned Main baseline before retirement. No start/reset/stop,
remote URL, persistent fixture, role attribute mutation or production SQL.
"""
from pathlib import Path
import argparse,json,re,subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--local-container',required=True)
parser.add_argument('--output-dir',type=Path,required=True,help='New evidence directory; existing directories are refused')
args=parser.parse_args()
if args.local_container!='supabase_db_database-engine-793':
    parser.error('Only the exact Database #793 isolated container is allowed; remote URLs are refused')
repo=Path(__file__).resolve().parents[3]
out=args.output_dir.resolve()
if out.exists():parser.error('--output-dir must be a new directory')
out.mkdir(parents=True)
container=args.local_container
assert subprocess.run(['docker','inspect','--format','{{.Name}}',container],check=True,capture_output=True,text=True).stdout.strip()=='/'+container
cmd=['docker','exec','-i',container,'psql','-X','-qAt','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
def run(q):return subprocess.run(cmd,input=q,text=True,capture_output=True,timeout=180)
migration=(repo/'supabase/migrations/20261007143357_retire_qualified_search_indexes.sql').read_text()
body=re.sub(r'^begin;\s*','',migration,count=1,flags=re.M)
body=re.sub(r'^commit;\s*$','',body,count=1,flags=re.M)
indexes=['private.lcia_scope_closure_issue_roots_issue_idx','public.lciamethods_json_idx','private.portal_catalog_search_process_document_v1_pgroonga','private.portal_catalog_search_process_exact_rank_v1_gin','public.lciamethods_json_pgroonga']
routines=['private.catalog_portal_process_keyword_relevance_v1_impl(text,text,uuid,text,integer,text)','private.catalog_portal_process_keyword_keys_v1(text,text,uuid,text,integer)','private.assert_portal_process_keyword_rank_contract_v1()','private.portal_process_keyword_rank_manifest_sha256_v1()']
def arr(xs):return 'array['+','.join("'"+x+"'" for x in xs)+']'
state="""select jsonb_build_object(
 'memberGraph',(select coalesce(jsonb_agg(to_jsonb(m) order by m.oid),'[]') from pg_auth_members m),
 'schemas',(select jsonb_agg(jsonb_build_object('name',nspname,'owner',nspowner,'acl',to_jsonb(nspacl)) order by oid)
   from pg_namespace where nspname in('private','public','api','util','archive')),
 'roles',(select jsonb_agg(to_jsonb(r) order by oid) from pg_roles r),
 'indexes',(select jsonb_agg(jsonb_build_object('oid',c.oid,'definition',pg_get_indexdef(c.oid),
   'owner',c.relowner,'options',c.reloptions,'index',to_jsonb(i)) order by c.oid)
   from pg_class c join pg_index i on i.indexrelid=c.oid where c.oid=any(array[
    'private.lcia_scope_closure_issue_roots_issue_idx'::regclass,'public.lciamethods_json_idx'::regclass,
    'private.portal_catalog_search_process_document_v1_pgroonga'::regclass,
    'private.portal_catalog_search_process_exact_rank_v1_gin'::regclass,'public.lciamethods_json_pgroonga'::regclass])),
 'routines',(select jsonb_agg(to_jsonb(p) order by p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='private' and p.proname in('catalog_portal_process_keyword_relevance_v1_impl',
    'catalog_portal_process_keyword_keys_v1','assert_portal_process_keyword_rank_contract_v1',
    'portal_process_keyword_rank_manifest_sha256_v1')),
 'apiGrants',(select jsonb_agg(to_jsonb(g) order by routine_identity) from private.api_capability_grants g))"""
# During the retired arm compare role/schema state separately; full original
# object metadata is verified after each connection's rollback.
role_state="""select jsonb_build_object(
 'memberGraph',(select coalesce(jsonb_agg(to_jsonb(m) order by m.oid),'[]') from pg_auth_members m),
 'schemas',(select jsonb_agg(jsonb_build_object('name',nspname,'owner',nspowner,'acl',to_jsonb(nspacl)) order by oid)
   from pg_namespace where nspname in('private','public','api','util','archive')),
 'roles',(select jsonb_agg(to_jsonb(r) order by oid) from pg_roles r))"""
pre=run(state+';');assert pre.returncode==0,pre.stderr;before=json.loads(pre.stdout.strip())
assert next(x for x in before['roles'] if x['rolname']=='postgres')['rolsuper'] is False
def assert_baseline():
    check=run(state+';')
    assert check.returncode==0,check.stderr
    assert json.loads(check.stdout.strip())==before,'Original role/schema/index/helper/API metadata was not restored'
receipts=[]
for option in ['absent','false','true']:
 configure='revoke portal_public_executor from postgres granted by postgres;' if option=='absent' else f'grant portal_public_executor to postgres with admin false,inherit false,set {option};'
 query='begin;\n'+configure+"\nselect set_config('test793.membership',("+role_state+")::text,true);\n"+body+'\n'+body+"\nselect jsonb_build_object('case','membership_"+option+"','replay',true,'membershipRestored',("+role_state+")=(current_setting('test793.membership')::jsonb),'allRetired',(select bool_and(to_regclass(x) is null) from unnest("+arr(indexes)+")x) and (select bool_and(to_regprocedure(x) is null) from unnest("+arr(routines)+")x));\nrollback;"
 r=run(query);(out/f'index-membership-{option}.log').write_text(r.stdout+r.stderr)
 records=[json.loads(l) for l in r.stdout.splitlines() if l.startswith('{')]
 receipt=records[-1] if records else {'case':'membership_'+option};receipt['exitCode']=r.returncode
 assert r.returncode==0 and receipt['membershipRestored'] and receipt['allRetired'],r.stderr
 assert_baseline();receipt['originalMetadataRestored']=True
 receipts.append(receipt);print(json.dumps(receipt),flush=True)
negative={
 'partial_absence':'drop index private.lcia_scope_closure_issue_roots_issue_idx;',
 'same_name_index_drift':'drop index public.lciamethods_json_idx;create index lciamethods_json_idx on public.lciamethods using gin(json jsonb_path_ops);',
 'external_helper_grant':'grant execute on function private.catalog_portal_process_keyword_keys_v1(text,text,uuid,text,integer) to anon;',
 'unexpected_caller':"create function private.issue793_unexpected_rank_caller() returns void language sql as 'select private.assert_portal_process_keyword_rank_contract_v1()';",
 'unexpected_procedure':"create procedure private.issue793_unexpected_rank_procedure() language plpgsql security definer as 'begin perform private.ASSERT_PORTAL_PROCESS_KEYWORD_RANK_CONTRACT_V1();end';",
 'unexpected_overload':"create function private.catalog_portal_process_keyword_keys_v1(integer) returns integer language sql as 'select $1';",
 'helper_config_drift':"grant portal_public_executor to postgres with inherit false,set true;set local role portal_public_executor;alter function private.catalog_portal_process_keyword_keys_v1(text,text,uuid,text,integer) set statement_timeout='9s';reset role;",
 'api_grant_drift':"insert into private.api_capability_grants(routine_identity,capability_id,allow_authenticated) values('private.catalog_portal_process_keyword_keys_v1(text,text,uuid,text,integer)','NX-CORE-02',true);"
}
for name,change in negative.items():
 # Permission to change a closed owner's metadata is temporary fixture authority,
 # separately rolled back with the deliberate negative state.
 if name=='external_helper_grant':change='grant portal_public_executor to postgres with inherit false,set true;set local role portal_public_executor;'+change+'reset role;'
 query='begin;\n'+change+'\n'+"select set_config('test793.membership',("+role_state+")::text,true);\n"+"do $test793$ declare refused boolean:=false;begin begin execute $migration793$"+body+"$migration793$;exception when sqlstate '55000' then refused:=true;end;if not refused then raise exception 'negative was accepted';end if;end $test793$;\n"+"select jsonb_build_object('case', '"+name+"','refused55000',true,'membershipRestored',("+role_state+")=current_setting('test793.membership')::jsonb,'routinesPreserved',(select bool_and(to_regprocedure(x) is not null) from unnest("+arr(routines)+")x));\nrollback;"
 r=run(query);(out/f'index-negative-{name}.log').write_text(r.stdout+r.stderr)
 records=[json.loads(l) for l in r.stdout.splitlines() if l.startswith('{')]
 receipt=records[-1] if records else {'case':name};receipt['exitCode']=r.returncode
 assert r.returncode==0 and receipt['membershipRestored'] and receipt['routinesPreserved'],r.stderr
 assert_baseline();receipt['originalMetadataRestored']=True
 receipts.append(receipt);print(json.dumps(receipt),flush=True)
for name in ['20261007_search_index_retirement.sql','20260826_portal_candidate_first_search.sql','20260722_data_product_scope_closure_and_task_feed.sql','20260722_scope_closure_release_binding_e2e.sql','20260729_scope_closure_artifact_retention.sql','20260730_scope_closure_staged_write_set_v2.sql']:
 source=(repo/'supabase/tests'/name).read_text();assert source.lower().startswith('begin;') or source.startswith('--')
 r=run('begin;\n'+body+'\n'+source)
 (out/(name+'.retired.tap.log')).write_text(r.stdout+r.stderr)
 tests=re.findall(r'^(?:not )?ok\s+(\d+)\b.*$',r.stdout,re.M);failures=re.findall(r'^not ok\b.*$',r.stdout,re.M);plans=re.findall(r'^1\.\.(\d+)\b',r.stdout,re.M)
 passed=r.returncode==0 and not failures and len(plans)==1 and len(tests)==int(plans[0]) and [int(n) for n in tests]==list(range(1,len(tests)+1))
 receipt={'case':name,'pass':passed,'exitCode':r.returncode,'assertions':len(tests),'failures':failures};assert_baseline();receipt['originalMetadataRestored']=True
 receipts.append(receipt);print(json.dumps(receipt),flush=True)
 assert passed,r.stderr+'\n'+repr(failures)
post=run(state+';');assert post.returncode==0;restored=json.loads(post.stdout.strip())==before
exist=run('select (select bool_and(to_regclass(x) is not null) from unnest('+arr(indexes)+')x) and (select bool_and(to_regprocedure(x) is not null) from unnest('+arr(routines)+')x);')
assert restored and exist.stdout.strip()=='t'
(out/'index-retirement-upgrade-receipt.json').write_text(json.dumps({'container':container,'migration':'20261007143357','postgresSuperuser':False,'receipts':receipts,'originalRoleGraphSchemaAndObjectsRestored':True,'retainedFixtures':[]},indent=2)+'\n')
print('All guard/replay/terminal/domain assertions passed; original role graph/schema/object state restored')
