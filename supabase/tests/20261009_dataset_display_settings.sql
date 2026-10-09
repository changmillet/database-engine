-- Database #799: reversible seven-type display, exact versions and unchanged source permissions.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

create temporary table open_data_webhook_calls (
  edge_function text not null,
  body jsonb not null,
  timeout_milliseconds integer not null
) on commit drop;

create or replace function util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds integer default ((5 * 60) * 1000)
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into pg_temp.open_data_webhook_calls(edge_function, body, timeout_milliseconds)
  values (name, body, timeout_milliseconds);
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
) values
  ('00000000-0000-0000-0000-000000000000','71200000-0000-4000-8000-000000000001',
   'authenticated','authenticated','open-data-manager@example.invalid','x',now(),'{}','{}',now(),now(),false,false),
  ('00000000-0000-0000-0000-000000000000','71200000-0000-4000-8000-000000000002',
   'authenticated','authenticated','open-data-owner@example.invalid','x',now(),'{}','{}',now(),now(),false,false);

insert into private.users(id, raw_user_meta_data, contact) values
  ('71200000-0000-4000-8000-000000000001','{}',null),
  ('71200000-0000-4000-8000-000000000002','{}',null);
insert into private.teams(id, json, rank, is_public)
values ('00000000-0000-0000-0000-000000000000','{"name":"System"}',0,false)
on conflict (id) do nothing;
insert into private.roles(user_id, team_id, role) values
  ('71200000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','data_product_manager');

insert into public.processes(
  id, version, state_code, user_id, json, search_text, embedding_ft, modified_at
) values
  ('71200000-0000-4000-8000-000000000010','01.00.000',100,null,
   '{"testScope":"open-data-712","label":"catalogtoken old","mention":"71200000-0000-4000-8000-000000000099"}',
   array['catalogtoken old'], array_fill(0.10::real,array[1024])::extensions.vector, now() - interval '2 days'),
  ('71200000-0000-4000-8000-000000000010','02.00.000',100,null,
   '{"testScope":"open-data-712","label":"catalogtoken latest","mention":"71200000-0000-4000-8000-000000000099"}',
   array['catalogtoken latest'], array_fill(0.10::real,array[1024])::extensions.vector, now() - interval '1 day'),
  ('71200000-0000-4000-8000-000000000011','01.00.000',100,
   '71200000-0000-4000-8000-000000000002',
   '{"testScope":"open-data-712","label":"catalogtoken enterprise"}',
   array['catalogtoken enterprise'], array_fill(0.20::real,array[1024])::extensions.vector, now()),
  ('71200000-0000-4000-8000-000000000012','01.00.000',0,null,
   '{"testScope":"open-data-712","label":"catalogtoken draft"}',
   array['catalogtoken draft'], null, now());

insert into public.contacts(id, version, state_code, user_id, json, search_text)
values
  ('71200000-0000-4000-8000-000000000020','01.00.000',100,null,
   '{"testScope":"open-data-712","label":"catalogtoken literature"}',array['catalogtoken literature']),
  ('71200000-0000-4000-8000-000000000021','01.00.000',100,
   '71200000-0000-4000-8000-000000000002',
   '{"testScope":"open-data-712","label":"catalogtoken enterprise"}',array['catalogtoken enterprise']);


insert into public.processes(id,version,state_code,user_id,json_ordered) values ('79900000-0000-4000-8000-000000000120','01.00.000',120,'71200000-0000-4000-8000-000000000002','{"processDataSet":{"processInformation":{"dataSetInformation":{"name":{"baseName":{"@xml:lang":"en","#text":"display120"}}}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}');
-- Every supported table and every exact version is a candidate, including foreign drafts/review states.
do $$ declare t text; begin
 foreach t in array array['flows','flowproperties','unitgroups','sources','lifecyclemodels'] loop
 execute format('insert into public.%I(id,version,state_code,user_id,json) values ($1,$2,20,$3,$4)',t)
 using '79900000-0000-4000-8000-000000000001'::uuid,'01.00.000'::character(9),'71200000-0000-4000-8000-000000000002'::uuid,'{}'::jsonb;
 end loop; end $$;
select ok(not exists(select 1 from information_schema.columns where table_schema='private' and table_name='dataset_display_settings' and column_name in ('published_by','updated_by','operator_id')),'configuration stores no operator');
select ok(not has_table_privilege('authenticated','private.dataset_display_catalog','select'),'private source projection is ACL closed');
select ok(not has_function_privilege('anon','api.list_displayed_datasets(text,text,integer,integer)','execute') and not has_function_privilege('service_role','api.cmd_dataset_display_set_batch(jsonb,boolean)','execute'),'anonymous and service mutation remain denied');
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','71200000-0000-4000-8000-000000000002',true);
select throws_ok($$select api.list_dataset_display_candidates()$$,'42501','data_product_manager role required','ordinary actor cannot enumerate all database candidates');
select throws_ok($$select api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"71200000-0000-4000-8000-000000000012","version":"01.00.000"}]',true)$$,'42501','data_product_manager role required','ordinary actor cannot configure display');
select is(api.list_displayed_datasets()->>'total','0','unconfigured versions are hidden');
select set_config('request.jwt.claim.sub','71200000-0000-4000-8000-000000000001',true);
select is(api.list_dataset_display_candidates('process')->>'total','5','manager sees every exact Process including foreign draft and state120');
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"71200000-0000-4000-8000-000000000012","version":"01.00.000"},{"datasetKind":"process","id":"71200000-0000-4000-8000-000000000012","version":"01.00.000"}]',true)#>>'{data,changedCount}','1','draft accepted and duplicate exact identities deduplicated');
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"79900000-0000-4000-8000-000000000120","version":"01.00.000"}]',true)#>>'{data,changedCount}','1','state120 accepts display without numerical publication');
reset role;
update private.dataset_display_settings set updated_at='2026-01-01T00:00:00Z' where dataset_id='79900000-0000-4000-8000-000000000120';
set local role authenticated;
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"79900000-0000-4000-8000-000000000120","version":"01.00.000"}]',true)#>>'{data,unchangedCount}','1','setting again is a no-op');
reset role;
select is((select updated_at from private.dataset_display_settings where dataset_id='79900000-0000-4000-8000-000000000120'),'2026-01-01T00:00:00Z'::timestamptz,'no-op preserves the original operation timestamp');
set local role authenticated;
select throws_ok($$select api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"71200000-0000-4000-8000-000000000010","version":"01.00.000"},{"datasetKind":"contact","id":"79900000-0000-4000-8000-000000000099","version":"01.00.000"}]',true)$$,'22023','all requested dataset versions must exist','mixed invalid batch rolls back earlier writes');
select is(api.list_displayed_datasets()->>'total','2','failed batch leaves no partial visibility');
select throws_ok($$select api.list_dataset_display_candidates('lciamethod')$$,'22023','invalid display list filters or pagination','LCIA methods excluded');
select throws_ok($$select api.cmd_dataset_display_set_batch('[{"datasetKind":"ilcd","id":"79900000-0000-4000-8000-000000000099","version":"01.00.000"}]',true)$$,'22023','each item must contain only a supported datasetKind, valid id and version','ILCD excluded');
select throws_ok($$select api.cmd_dataset_display_set_batch('[]',true)$$,'22023','items must contain between 1 and 100 exact dataset versions','empty batch rejected');
select throws_ok($$select api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"71200000-0000-4000-8000-000000000012","version":"01.00.000","state_code":100}]',true)$$,'22023','each item must contain only a supported datasetKind, valid id and version','caller cannot alter source state');
select throws_ok($$select api.list_displayed_datasets('all','',101,1)$$,'22023','invalid display list filters or pagination','page size bounded');
select throws_ok($$select api.list_displayed_datasets('all','',1,2147483647)$$,'22023','invalid display list filters or pagination','offset bounded');
select is(api.list_displayed_datasets('flow')->>'total','0','type filter excludes Process');
select is(jsonb_array_length(api.list_displayed_datasets('all','',1,3)->'data'),0,'empty page retains total count');
select is(api.list_displayed_datasets('all','',1,3)->>'total','2','count precedes page');
select set_config('request.jwt.claim.sub','71200000-0000-4000-8000-000000000002',true);
select is(api.list_displayed_datasets('process','display120')->>'total','1','ordinary actor reads selected name projection');
select ok(not ((api.list_displayed_datasets('process','display120')->'data'->0) ?| array['json','user_id','team_id','state_code','is_visible']),'displayed response excludes raw source and owner metadata');
select is((select count(*)::text from public.processes where id='79900000-0000-4000-8000-000000000120'),'0','raw state120 RLS remains closed even after selection');
select set_config('request.jwt.claim.sub','71200000-0000-4000-8000-000000000001',true);
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"79900000-0000-4000-8000-000000000120","version":"01.00.000"}]',false)#>>'{data,changedCount}','1','cancel stores false');
select is(api.cmd_dataset_display_set_batch('[{"datasetKind":"process","id":"79900000-0000-4000-8000-000000000120","version":"01.00.000"}]',false)#>>'{data,unchangedCount}','1','cancel retry is a no-op');
select is(api.list_displayed_datasets('process','display120')->>'total','0','cancel disappears immediately');
reset role;
select is((select state_code::text from public.processes where id='79900000-0000-4000-8000-000000000120'),'120','source lifecycle remains unchanged');
select is((select is_visible::text from private.dataset_display_settings where dataset_id='79900000-0000-4000-8000-000000000120'),'false','false configuration retained without history');
select ok((select updated_at>'2026-01-01T00:00:00Z'::timestamptz from private.dataset_display_settings where dataset_id='79900000-0000-4000-8000-000000000120'),'actual visibility change updates the operation timestamp');
-- Batch across all seven kinds, with no owner/team/state requirement.
select set_config('request.jwt.claim.sub','71200000-0000-4000-8000-000000000001',true);
select is(api.cmd_dataset_display_set_batch((select jsonb_agg(jsonb_build_object('datasetKind',dataset_kind,'id',dataset_id,'version',dataset_version)) from private.dataset_display_catalog),true)#>>'{data,requestedCount}','12','all seven kinds and all versions selectable');
select is((select count(distinct x->>'dataset_kind')::text from jsonb_array_elements(api.list_displayed_datasets('all','',100,1)->'data') x),'7','display projection spans exactly seven types');
select is(api.list_dataset_display_candidates('all','visible')->>'total','12','visibility filter and total agree');
select is(api.list_dataset_display_candidates('all','hidden')->>'total','0','hidden filter excludes all selected versions');
insert into public.contacts(id,version,state_code,json) values ('71200000-0000-4000-8000-000000000020','02.00.000',0,'{}');
select is(api.list_dataset_display_candidates('contact','hidden')->>'total','1','new version does not inherit display');
delete from public.contacts where id='71200000-0000-4000-8000-000000000020' and version='01.00.000';
select is((select count(*)::text from private.dataset_display_settings where dataset_kind='contact' and dataset_id='71200000-0000-4000-8000-000000000020'),'0','source deletion clears only exact configuration');
select throws_ok($$update public.contacts set version='03.00.000' where id='71200000-0000-4000-8000-000000000021'$$,'55000','APPROVED_DATASET_IMMUTABLE','display does not bypass approved source immutability');
select api.cmd_dataset_display_set_batch('[{"datasetKind":"contact","id":"71200000-0000-4000-8000-000000000020","version":"02.00.000"}]',true);
update public.contacts set version='03.00.000' where id='71200000-0000-4000-8000-000000000020' and version='02.00.000';
select is((select count(*)::text from private.dataset_display_settings where dataset_kind='contact' and dataset_id='71200000-0000-4000-8000-000000000020'),'0','admitted source identity replacement clears exact configuration');
select set_config('request.jwt.claim.sub','',true);
select throws_ok($$select api.list_displayed_datasets()$$,'28000','authentication required','projection requires actor even under definer');
select * from finish();
rollback;
