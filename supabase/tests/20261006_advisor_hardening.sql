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

-- These names deliberately precede pg_catalog for this hostile caller. Each
-- hardened helper must resolve its own qualified/implicit catalog dependencies.
create function pg_temp.jsonb_typeof(jsonb) returns text language sql immutable as $$select 'hostile'::text$$;
create function pg_temp.jsonb_object_keys(jsonb) returns setof text language sql immutable as $$select 'hostile'::text$$;
create function pg_temp.jsonb_array_elements(jsonb) returns setof jsonb language sql immutable as $$select '"hostile"'::jsonb$$;
set local search_path=pg_temp,pg_catalog,extensions;
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
