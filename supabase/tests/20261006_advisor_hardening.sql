-- Database #785: hostile namespaces, closed invokers and exact policy role sets.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public;
select no_plan();

with expected(signature) as (values
 ('private.dataset_alias_v2_deny(text,integer,text,jsonb)'),
 ('private.dataset_alias_v2_derivative_chunks(uuid,text,jsonb)'),
 ('private.dataset_alias_v2_derivative_target_ok(jsonb)'),
 ('private.dataset_alias_v2_exchange_keys_ok(jsonb)'),
 ('private.dataset_alias_v2_multiply_amount(text,text)'),
 ('private.dataset_alias_v2_plan_keys_ok(jsonb)'),
 ('private.dataset_alias_v2_replace_exchange_amounts(jsonb,jsonb)'),
 ('private.dataset_alias_v2_replace_flow_reference(jsonb,jsonb)'),
 ('private.dataset_alias_v2_replace_fu_text(jsonb,jsonb)'),
 ('private.dataset_length_time_v1_multiply_amount(text)'),
 ('private.dataset_length_time_v1_plan_keys_ok(jsonb)'),
 ('private.dataset_length_time_v1_replace_exchange_amounts(jsonb,jsonb)'),
 ('private.portal_navigation_version_matches_v3(text,jsonb,uuid,text)'))
select ok(not p.prosecdef and p.proconfig=array['search_path=""']
 and not has_function_privilege('anon',p.oid,'EXECUTE')
 and not has_function_privilege('authenticated',p.oid,'EXECUTE'),
 expected.signature||' has a fixed invoker path and remains externally closed')
from expected join pg_proc p on p.oid=expected.signature::regprocedure;

-- The permitted role sets remain exact; restrictive OAuth and Process120
-- policies are exercised by the independent existing authorization suites.
with expected(table_name) as(values('flowproperties'),('flows'),('lifecyclemodels'),('processes'),('sources'),('unitgroups'))
select is((select count(*) from pg_policy p where p.polrelid=('public.'||table_name)::regclass
 and p.polcmd='r' and p.polpermissive and p.polroles=array['authenticated'::regrole::oid]),
 1::bigint,table_name||' has one exact authenticated permissive SELECT policy') from expected;
select ok(exists(select 1 from pg_policy where polrelid='public.contacts'::regclass
 and polname='Enable read access for authenticated users' and polroles=array[0::oid])
 and exists(select 1 from pg_policy where polrelid='public.contacts'::regclass
 and polname='authenticated_example_read' and polroles=array['authenticated'::regrole::oid]),
 'Contacts preserves its PUBLIC and authenticated role boundaries');

-- PostgreSQL never searches pg_temp for functions/operators. Use an ordinary
-- transaction-owned schema and prove lookup really reaches its hostile names.
create schema issue785_hostile authorization postgres;
create function issue785_hostile.jsonb_typeof(jsonb) returns text language sql immutable as $$select 'hostile'::text$$;
create function issue785_hostile.jsonb_object_keys(jsonb) returns setof text language sql immutable as $$select 'hostile'::text$$;
create function issue785_hostile.jsonb_array_elements(jsonb) returns setof jsonb language sql immutable as $$select '"hostile"'::jsonb$$;
set local search_path=issue785_hostile,pg_catalog,extensions;
select extensions.is(jsonb_typeof('{}'::jsonb),'hostile','ordinary-schema canary actually shadows catalog function lookup');
select extensions.is((select array_agg(k) from jsonb_object_keys('{"meanAmount":"1"}') k),array['hostile'],
 'ordinary-schema set-returning canary actually shadows catalog function lookup');
-- Restore only the exact original no-SET configuration, never change the body.
alter function private.dataset_alias_v2_exchange_keys_ok(jsonb) reset search_path;
select extensions.is(private.dataset_alias_v2_exchange_keys_ok('{"meanAmount":"1"}'),false,
 'original mutable caller path can change this owner-level helper result');
alter function private.dataset_alias_v2_exchange_keys_ok(jsonb) set search_path='';
select extensions.is(private.dataset_alias_v2_exchange_keys_ok('{"meanAmount":"1"}'),true,
 'fixed SQL invoker ignores hostile jsonb functions');
select extensions.is(private.dataset_alias_v2_plan_keys_ok('{"hostile":true}'),false,
 'closed plan key set cannot be bypassed through caller search_path');
select extensions.is(private.dataset_alias_v2_multiply_amount('1','0.00011415525114155251'),
 '0.00011415525114155251','fixed PL invoker preserves exact amount derivation');
select extensions.is(private.dataset_length_time_v1_multiply_amount('0.0198'),'19.8',
 'length-time derivation survives hostile caller search_path');
select extensions.is(private.dataset_alias_v2_derivative_chunks('78500000-0000-4000-8000-000000000001',repeat('a',64),'[]'),
 '[]'::jsonb,'complex SQL invoker ignores hostile set-returning function');
grant usage on schema issue785_hostile to authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"78500000-0000-4000-8000-000000000099","email":"fixture@example.invalid"}',true);
set local role authenticated;
select extensions.is(api.cmd_dataset_alias_execution_preflight_v2_guarded('{}')->>'code',
 'ALIAS_EXECUTION_PREFLIGHT_INVALID_REQUEST','real protected facade retains its fixed-path request validation under a hostile caller namespace');
reset role;

set local search_path=extensions,public;
set local role service_role;
select extensions.is(private.lcia_scope_closure_bundle_binding_matches(
 null::private.lcia_scope_closure_checks,null::private.worker_job_artifacts),false,
 'existing service caller can reach the reconciled binding helper, which fails closed without evidence');
reset role;
select ok(not has_function_privilege('anon','private.lcia_scope_closure_bundle_binding_matches(private.lcia_scope_closure_checks,private.worker_job_artifacts)','EXECUTE')
 and not has_function_privilege('authenticated','private.lcia_scope_closure_bundle_binding_matches(private.lcia_scope_closure_checks,private.worker_job_artifacts)','EXECUTE'),
 'binding-helper reconciliation does not open browser execution');
select * from finish();
rollback;
