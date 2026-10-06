-- Database #785: pin thirteen non-inlined private invokers, preserving scalar SQL
-- inlining on twelve exact-signature exceptions. No body, ACL or API change.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create temp table issue785_invoker_prestate on commit drop as
select p.* from pg_catalog.pg_proc p where p.oid in (
  'private.dataset_alias_v2_deny(text,integer,text,jsonb)'::regprocedure,
  'private.dataset_alias_v2_derivative_chunks(uuid,text,jsonb)'::regprocedure,
  'private.dataset_alias_v2_derivative_target_ok(jsonb)'::regprocedure,
  'private.dataset_alias_v2_exchange_keys_ok(jsonb)'::regprocedure,
  'private.dataset_alias_v2_multiply_amount(text,text)'::regprocedure,
  'private.dataset_alias_v2_plan_keys_ok(jsonb)'::regprocedure,
  'private.dataset_alias_v2_replace_exchange_amounts(jsonb,jsonb)'::regprocedure,
  'private.dataset_alias_v2_replace_flow_reference(jsonb,jsonb)'::regprocedure,
  'private.dataset_alias_v2_replace_fu_text(jsonb,jsonb)'::regprocedure,
  'private.dataset_length_time_v1_multiply_amount(text)'::regprocedure,
  'private.dataset_length_time_v1_plan_keys_ok(jsonb)'::regprocedure,
  'private.dataset_length_time_v1_replace_exchange_amounts(jsonb,jsonb)'::regprocedure,
  'private.portal_navigation_version_matches_v3(text,jsonb,uuid,text)'::regprocedure);
do $guard$
declare f record; p record;
begin
 for f in select * from (values
    ('private.dataset_alias_v2_deny(text,integer,text,jsonb)','2d93f8e55efc45ab1718d9801935f59c','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_derivative_chunks(uuid,text,jsonb)','d40086bbd15c1fd28b9908281dc3d525','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_derivative_target_ok(jsonb)','ec64dc25064a519886b21698a30d5952','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_exchange_keys_ok(jsonb)','e3c31dab373f3070786cb18fd9ab6d9c','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_multiply_amount(text,text)','617633b3bcada41cbe70df980cba90e6','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_plan_keys_ok(jsonb)','9b6b407484419a6fc1f3108c30a68c59','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_replace_exchange_amounts(jsonb,jsonb)','52d977c80a128f305c3d31b19d7b1a6c','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_replace_flow_reference(jsonb,jsonb)','e45ad60c6a50ce0557bb3fe6f9ce07b2','postgres','{postgres=X/postgres}'),
    ('private.dataset_alias_v2_replace_fu_text(jsonb,jsonb)','9ca41ba810ff876f60477f9daf9c94eb','postgres','{postgres=X/postgres}'),
    ('private.dataset_length_time_v1_multiply_amount(text)','abc4849eb6adcc6f27373beb68dc1525','postgres','{postgres=X/postgres}'),
    ('private.dataset_length_time_v1_plan_keys_ok(jsonb)','ab678c14ffcd8368744d9e663e081fc8','postgres','{postgres=X/postgres}'),
    ('private.dataset_length_time_v1_replace_exchange_amounts(jsonb,jsonb)','655c78e6d8b7646ee4432c8b75b9a5bf','postgres','{postgres=X/postgres}'),
    ('private.portal_navigation_version_matches_v3(text,jsonb,uuid,text)','ffa0ecbbb2ddb65dd627653bd5965d35','portal_public_executor','{portal_public_executor=X/portal_public_executor}')
 ) expected(signature,body_md5,owner_name,acl_text) loop
  select * into strict p from pg_catalog.pg_proc where oid=f.signature::regprocedure;
  if p.prosecdef or pg_catalog.md5(p.prosrc) is distinct from f.body_md5
     or p.proowner is distinct from f.owner_name::regrole or p.proacl::text is distinct from f.acl_text
     or not (p.proconfig is null or p.proconfig=array['search_path=""']) then
   raise exception using errcode='55000',message='Database #785 invoker prestate drift';
  end if;
 end loop;
end;
$guard$;
alter function private.dataset_alias_v2_deny(text,integer,text,jsonb) set search_path='';
alter function private.dataset_alias_v2_derivative_chunks(uuid,text,jsonb) set search_path='';
alter function private.dataset_alias_v2_derivative_target_ok(jsonb) set search_path='';
alter function private.dataset_alias_v2_exchange_keys_ok(jsonb) set search_path='';
alter function private.dataset_alias_v2_multiply_amount(text,text) set search_path='';
alter function private.dataset_alias_v2_plan_keys_ok(jsonb) set search_path='';
alter function private.dataset_alias_v2_replace_exchange_amounts(jsonb,jsonb) set search_path='';
alter function private.dataset_alias_v2_replace_flow_reference(jsonb,jsonb) set search_path='';
alter function private.dataset_alias_v2_replace_fu_text(jsonb,jsonb) set search_path='';
alter function private.dataset_length_time_v1_multiply_amount(text) set search_path='';
alter function private.dataset_length_time_v1_plan_keys_ok(jsonb) set search_path='';
alter function private.dataset_length_time_v1_replace_exchange_amounts(jsonb,jsonb) set search_path='';
-- The Portal helper retains its existing NOLOGIN/NOBYPASSRLS owner. Only
-- transaction-local SET authority is borrowed; existing grant options restore.
do $acl_begin$
declare before_grant jsonb;
begin
 select jsonb_build_object('admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option)
 into before_grant from pg_catalog.pg_auth_members m
 where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole
   and m.grantor=current_user::regrole;
 perform pg_catalog.set_config('advisor785.portal_grant',coalesce(before_grant,'null'::jsonb)::text,true);
 grant portal_public_executor to postgres with set true;
end;
$acl_begin$;
set local role portal_public_executor;
alter function private.portal_navigation_version_matches_v3(text,jsonb,uuid,text) set search_path='';
reset role;
do $acl_end$
declare before_grant jsonb;
begin
 before_grant:=pg_catalog.current_setting('advisor785.portal_grant')::jsonb;
 if before_grant='null'::jsonb then revoke portal_public_executor from postgres;
 else
  execute pg_catalog.format('grant portal_public_executor to postgres with admin %s, inherit %s, set %s',
    before_grant->>'admin',before_grant->>'inherit',before_grant->>'set');
 end if;
 if exists(select 1 from issue785_invoker_prestate b full join pg_catalog.pg_proc p using(oid)
   where b.oid is not null and (p.oid is null or p.proconfig is distinct from array['search_path=""']
    or (to_jsonb(b)-'proconfig') is distinct from (to_jsonb(p)-'proconfig'))) then
  raise exception using errcode='55000',message='Database #785 invoker metadata changed';
 end if;
end;
$acl_end$;
commit;
