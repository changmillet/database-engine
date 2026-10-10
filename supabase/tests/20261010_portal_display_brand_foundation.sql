begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,api,private;
select no_plan();

select is(private.portal_normalize_brand_scope_v1(array['worldsteel','bafu','bafu','tiangong_lca']),array['bafu','tiangong_lca','worldsteel'],'scope sorts and deduplicates');
select is(private.portal_normalize_brand_scope_v1(array['uslci']),array['uslci'],'one-brand scope');
select throws_ok($$select private.portal_normalize_brand_scope_v1(null)$$,'22023','invalid portal brand scope','missing scope fails closed');
select throws_ok($$select private.portal_normalize_brand_scope_v1('{}')$$,'22023','invalid portal brand scope','empty scope fails closed');
select throws_ok($$select private.portal_normalize_brand_scope_v1(array['*'])$$,'22023','invalid portal brand scope','wildcard rejected');
select throws_ok($$select private.portal_normalize_brand_scope_v1(array['Tiangong LCA'])$$,'22023','invalid portal brand scope','display label is not a code');
select throws_ok($$select private.portal_normalize_brand_scope_v1(array['bafu',null])$$,'22023','invalid portal brand scope','null member rejected');
select throws_ok($$select private.portal_normalize_brand_scope_v1(array[['bafu','uslci']])$$,'22023','invalid portal brand scope','multidimensional arrays rejected');
select throws_ok($$select private.portal_normalize_brand_scope_v1(array_fill('bafu'::text,array[5]))$$,'22023','invalid portal brand scope','input size bounded before normalization');
select is(private.portal_brand_v1('tiangong_lca'),' {"code":"tiangong_lca","name":"Tiangong LCA"}'::jsonb,'Tiangong label is exact');
select is(private.portal_brand_v1('bafu')->>'name','BAFU','BAFU label');
select is(private.portal_brand_v1('uslci')->>'name','USLCI','USLCI label');
select is(private.portal_brand_v1('worldsteel')->>'name','World steel','World steel label');
select is(private.portal_brand_v1(null),null::jsonb,'unassigned is never inferred');
select is(private.portal_brand_v1('unknown'),null::jsonb,'unknown has no public brand');

-- Synthetic exact configuration tests; the helper is deliberately not a source
-- existence or publication predicate. Source-backed consumers validate those.
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand,updated_at) values
 ('process','80700000-0000-4000-8000-000000000001','01.00.000',true,'tiangong_lca','2026-01-01Z'),
 ('process','80700000-0000-4000-8000-000000000001','02.00.000',false,'bafu','2026-01-01Z'),
 ('flow','80700000-0000-4000-8000-000000000002','01.00.000',true,'bafu','2026-01-01Z'),
 ('unitgroup','80700000-0000-4000-8000-000000000003','01.00.000',true,null,'2026-01-01Z');
select ok(private.portal_dataset_in_brand_scope_v1('process','80700000-0000-4000-8000-000000000001','01.00.000',array['tiangong_lca']),'root is inside its deployment scope');
select ok(not private.portal_dataset_in_brand_scope_v1('process','80700000-0000-4000-8000-000000000001','01.00.000',array['bafu']),'root excluded from other scope');
select ok(not private.portal_dataset_in_brand_scope_v1('process','80700000-0000-4000-8000-000000000001','02.00.000',array['bafu']),'brand does not override hidden flag');
select ok(not private.portal_dataset_is_visible_v1('process','80700000-0000-4000-8000-000000000001','03.00.000'),'new exact version does not inherit');
select ok(not private.portal_dataset_is_visible_v1('process','80700000-0000-4000-8000-000000000001','01.00.000suffix'),'long version cannot alias character(9) identity');
select ok(not private.portal_dataset_is_visible_v1('flow','80700000-0000-4000-8000-000000000001','01.00.000'),'kind is part of identity');
select ok(private.portal_dataset_is_visible_v1('flow','80700000-0000-4000-8000-000000000002','01.00.000'),'cross-brand dependency is globally visible');
select ok(not private.portal_dataset_in_brand_scope_v1('flow','80700000-0000-4000-8000-000000000002','01.00.000',array['tiangong_lca']),'dependency is not a Tiangong root');
select ok(private.portal_dataset_is_visible_v1('unitgroup','80700000-0000-4000-8000-000000000003','01.00.000'),'unassigned dependency is globally visible');
select ok(not private.portal_dataset_in_brand_scope_v1('unitgroup','80700000-0000-4000-8000-000000000003','01.00.000',array['tiangong_lca','bafu','uslci','worldsteel']),'null brand never matches deployment set');
select throws_ok($$insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,brand) values ('flow','80700000-0000-4000-8000-000000000099','01.00.000','unknown')$$,'23514',null,'brand constraint rejects unknown');
update private.dataset_display_settings set brand=brand where dataset_id='80700000-0000-4000-8000-000000000003';
select is((select updated_at from private.dataset_display_settings where dataset_id='80700000-0000-4000-8000-000000000003'),'2026-01-01Z'::timestamptz,'no-op preserves timestamp');
update private.dataset_display_settings set brand='uslci' where dataset_id='80700000-0000-4000-8000-000000000003';
select ok((select updated_at>'2026-01-01Z'::timestamptz from private.dataset_display_settings where dataset_id='80700000-0000-4000-8000-000000000003'),'brand change updates timestamp');
update private.dataset_display_settings set is_visible=false where dataset_id='80700000-0000-4000-8000-000000000002';
select ok(not private.portal_dataset_is_visible_v1('flow','80700000-0000-4000-8000-000000000002','01.00.000'),'withdrawal immediately changes global predicate');

select ok(not has_table_privilege('anon','private.dataset_display_settings','select'),'settings remain private to anon');
select ok(not has_table_privilege('authenticated','private.dataset_display_settings','select'),'settings remain private to authenticated');
select ok(not has_table_privilege('portal_public_executor','private.dataset_display_settings','select'),'executor gets only narrow helper, not settings table');
select ok(not has_function_privilege('anon','private.portal_dataset_is_visible_v1(text,uuid,text)','execute'),'no anonymous helper grant');
select ok(not has_function_privilege('authenticated','private.portal_dataset_in_brand_scope_v1(text,uuid,text,text[])','execute'),'no authenticated scope helper grant');
select ok(has_function_privilege('portal_public_executor','private.portal_dataset_is_visible_v1(text,uuid,text)','execute'),'Portal executor may evaluate policy predicate');
select ok(not has_function_privilege('service_role','private.portal_dataset_is_visible_v1(text,uuid,text)','execute'),'no service helper grant');
grant portal_public_executor to postgres;
set local role portal_public_executor;
select ok(private.portal_dataset_in_brand_scope_v1('process','80700000-0000-4000-8000-000000000001','01.00.000',array['tiangong_lca']),'least-privilege executor can use scoped predicate');
reset role;
-- The unchanged manager command must preserve an assigned brand on both set
-- and cancel, and must not assign one to a newly configured exact version.
-- Keep source triggers active, but contain outbound work in this rolled-back
-- fixture, as in the existing display command regression suite.
create or replace function util.invoke_edge_function(
  name text, body jsonb, timeout_milliseconds integer default ((5 * 60) * 1000)
) returns void language plpgsql security definer set search_path = '' as $$
begin
  return;
end;
$$;
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values ('80700000-0000-4000-8000-000000000080','authenticated','authenticated','portal-807@example.invalid','x',now(),'{}','{}',now(),now());
insert into private.teams(id,json,rank,is_public)
values('00000000-0000-0000-0000-000000000000','{"name":"System"}',0,false) on conflict(id) do nothing;
insert into private.roles(user_id,team_id,role)
values('80700000-0000-4000-8000-000000000080','00000000-0000-0000-0000-000000000000','data_product_manager');
insert into public.processes(id,version,state_code,json)
values('80700000-0000-4000-8000-000000000081','01.00.000',0,'{}');
set local role authenticated;
select set_config('request.jwt.claim.sub','80700000-0000-4000-8000-000000000080',true);
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"80700000-0000-4000-8000-000000000081","version":"01.00.000"}]',true)#>>'{data,changedCount}','1','existing manager command inserts setting');
reset role;
select is((select brand from private.dataset_display_settings where dataset_id='80700000-0000-4000-8000-000000000081'),null::text,'manager insert does not infer brand');
update private.dataset_display_settings set brand='bafu' where dataset_id='80700000-0000-4000-8000-000000000081';
set local role authenticated;
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"80700000-0000-4000-8000-000000000081","version":"01.00.000"}]',false)#>>'{data,changedCount}','1','existing manager cancellation works');
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"80700000-0000-4000-8000-000000000081","version":"01.00.000"}]',true)#>>'{data,changedCount}','1','existing manager setting works');
reset role;
select is((select brand from private.dataset_display_settings where dataset_id='80700000-0000-4000-8000-000000000081'),'bafu','set/cancel preserve existing brand');
select * from finish();
rollback;
