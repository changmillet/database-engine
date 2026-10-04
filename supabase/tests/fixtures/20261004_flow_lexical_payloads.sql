-- Synthetic fixtures; callers must open a transaction and roll it back.
set local search_path = public, extensions, auth;
alter table public.flows disable trigger user;
insert into auth.users(id,instance_id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
 ('77400000-0000-4000-8000-000000000901','00000000-0000-0000-0000-000000000000','authenticated','authenticated','flow774-owner@example.invalid','{}','{}',now(),now()),
 ('77400000-0000-4000-8000-000000000902','00000000-0000-0000-0000-000000000000','authenticated','authenticated','flow774-other@example.invalid','{}','{}',now(),now());
insert into private.users(id,raw_user_meta_data) values
 ('77400000-0000-4000-8000-000000000901','{}'),
 ('77400000-0000-4000-8000-000000000902','{}');
insert into private.teams(id,json,rank,is_public) values
 ('77400000-0000-4000-8000-000000000903','{"name":"fixture team"}',1,false),
 ('77400000-0000-4000-8000-000000000904','{"name":"foreign fixture team"}',1,false);
insert into private.roles(user_id,team_id,role) values
 ('77400000-0000-4000-8000-000000000901','77400000-0000-4000-8000-000000000903','member');
create function pg_temp.flow_774_fixture(
 p_id integer,p_version text,p_state integer,p_day integer,p_token text,p_label text,
 p_type text default 'Product flow',p_class text default 'C2',p_emission boolean default false,
 p_owner uuid default '77400000-0000-4000-8000-000000000902',p_team uuid default null
) returns void language sql as $$
 insert into public.flows(id,version,state_code,modified_at,user_id,team_id,json,json_ordered,search_text)
 values (('77400000-0000-4000-8000-'||lpad(p_id::text,12,'0'))::uuid,p_version,p_state,
 '2026-01-01'::timestamptz+p_day*interval '1 day',p_owner,p_team,
 jsonb_build_object('label',p_label,'history','match','flowDataSet',jsonb_build_object(
 'modellingAndValidation',jsonb_build_object('LCIMethod',jsonb_build_object('typeOfDataSet',p_type)),
 'flowInformation',jsonb_build_object('dataSetInformation',jsonb_build_object('classificationInformation',jsonb_build_object(
 'common:classification',jsonb_build_object('common:class',jsonb_build_object('@classId',p_class)),
 'common:elementaryFlowCategorization',jsonb_build_object('common:category',jsonb_build_array(jsonb_build_object('@catId','E1','@level','0','#text',case when p_emission then 'Emissions' else 'Resources' end)))))))),
 '{}',array[p_token]);
$$;
select pg_temp.flow_774_fixture(1,'01.00.000',100,1,'flow774token','old','Product flow','C1',true);
select pg_temp.flow_774_fixture(1,'01.00.001',100,5,'unmatched','latest','Elementary flow','C9');
select pg_temp.flow_774_fixture(2,'01.00.000',100,4,'flow774token','second');
select pg_temp.flow_774_fixture(3,'01.00.000',200,3,'flow774token','contributed');
select pg_temp.flow_774_fixture(4,'01.00.000',0,2,'flow774token','owner','Product flow','C2',false,'77400000-0000-4000-8000-000000000901');
select pg_temp.flow_774_fixture(5,'01.00.000',0,2,'flow774token','foreign');
select pg_temp.flow_774_fixture(6,'01.00.000',0,2,'flow774token','team','Product flow','C2',false,'77400000-0000-4000-8000-000000000902','77400000-0000-4000-8000-000000000903');
select pg_temp.flow_774_fixture(7,'01.00.000',0,2,'flow774token','foreign-team','Product flow','C2',false,'77400000-0000-4000-8000-000000000902','77400000-0000-4000-8000-000000000904');
select pg_temp.flow_774_fixture(8,'01.00.000',20,2,'flow774token','owner-review','Product flow','C2',false,'77400000-0000-4000-8000-000000000901');
select pg_temp.flow_774_fixture(9,'01.00.000',-1,2,'flow774token','example');
create function pg_temp.flow_774_page(
 p_query text default 'flow774token',p_filter jsonb default '{}',p_source text default 'tg',
 p_size bigint default 10,p_page bigint default 1,p_actor text default '',
 p_team uuid default null,p_state integer default null
) returns jsonb language sql as $$
 select coalesce(jsonb_agg(to_jsonb(r) order by r.rank,r.id),'[]'::jsonb)
 from api.search_flows_latest(p_query,p_filter,'{}'::jsonb,p_size,p_page,p_source,p_actor,p_team,p_state,array[p_query]) r;
$$;
grant execute on function pg_temp.flow_774_page(text,jsonb,text,bigint,bigint,text,uuid,integer) to authenticated;
