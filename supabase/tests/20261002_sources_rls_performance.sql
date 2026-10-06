-- Database #766: compare the retained baseline with the deployed replacement.
-- Every fixture and policy change rolls back. Actor reads use authenticated RLS.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select plan(44);
create temp table source_policy_layout as select not exists(
 select 1 from pg_policy where polrelid='public.sources'::regclass
 and polname='authenticated_example_read') as merged_examples;
create temporary table policy_variants(name text primary key, ddl text);
insert into policy_variants
select 'new',format('alter policy "Enable read access for authenticated users" on public.sources using (%s)',qual)
from pg_policies where schemaname='public' and tablename='sources' and policyname='Enable read access for authenticated users';
insert into policy_variants values ('old',$baseline$ALTER POLICY "Enable read access for authenticated users" ON "public"."sources" USING ((("state_code" >= 100) OR (( SELECT "auth"."uid"() AS "uid") = "user_id") OR (EXISTS ( SELECT 1
   FROM "private"."roles"
  WHERE (("roles"."team_id" = "sources"."team_id") AND (("roles"."role")::"text" = ANY (ARRAY[('admin'::character varying)::"text", ('member'::character varying)::"text", ('owner'::character varying)::"text"])) AND ("roles"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))) OR (("state_code" = 20) AND ((EXISTS ( SELECT 1
   FROM "private"."roles"
  WHERE (("roles"."team_id" = '00000000-0000-0000-0000-000000000000'::"uuid") AND (("roles"."role")::"text" = 'review-admin'::"text") AND ("roles"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))) OR (EXISTS ( SELECT 1
   FROM "private"."reviews" "r"
  WHERE (("r"."state_code" > 0) AND (((("r"."json" -> 'data'::"text") ->> 'id'::"text"))::"uuid" = "sources"."id") AND ((("r"."json" -> 'data'::"text") ->> 'version'::"text") = ("sources"."version")::"text") AND ("r"."reviewer_id" @> "jsonb_build_array"((( SELECT "auth"."uid"() AS "uid"))::"text"))))) OR (EXISTS ( SELECT 1
   FROM "private"."reviews" "r"
  WHERE (("r"."id" IN ( SELECT (("review_item"."value" ->> 'id'::"text"))::"uuid" AS "uuid"
           FROM "jsonb_array_elements"("sources"."reviews") "review_item"("value"))) AND ("r"."reviewer_id" @> "jsonb_build_array"((( SELECT "auth"."uid"() AS "uid"))::"text")))))))));$baseline$);
create function pg_temp.capture_actor(p_actor uuid,p_client uuid default null,p_source uuid default null) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claim.sub',coalesce(p_actor::text,''),true);
 perform set_config('request.jwt.claims',jsonb_strip_nulls(jsonb_build_object('role','authenticated','sub',p_actor,'client_id',p_client))::text,true);
 execute 'set local role authenticated';
 begin
  select jsonb_agg(jsonb_build_array(id,version) order by id,version) into result
  from public.sources where id::text like '76610000-%' and (p_source is null or id=p_source);
  result:=jsonb_build_object('rows',coalesce(result,'[]'));
 exception when others then result:=jsonb_build_object('sqlstate',sqlstate);
 end;
 execute 'reset role';
 return result;
end $$;
create function pg_temp.parity(p_actor uuid,p_label text,p_expected jsonb default null,p_client uuid default null,p_source uuid default null)
returns setof text language plpgsql as $$
declare before_value jsonb; after_value jsonb;
begin
 execute (select ddl from policy_variants where name='old');
 -- #785 folded the old companion into the current policy. Reconstruct the
 -- predecessor's original two-policy layout only while measuring it.
 if (select merged_examples from source_policy_layout) then
  execute 'create policy authenticated_example_read on public.sources for select to authenticated using (state_code=-1 and (select auth.uid()) is not null)';
 end if;
 before_value:=pg_temp.capture_actor(p_actor,p_client,p_source);
 execute (select ddl from policy_variants where name='new');
 if (select merged_examples from source_policy_layout) then
  execute 'drop policy authenticated_example_read on public.sources';
 end if;
 after_value:=pg_temp.capture_actor(p_actor,p_client,p_source);
 return next extensions.is(after_value,before_value,p_label||' preserves predecessor result or SQLSTATE');
 if p_expected is not null then
  return next extensions.is(after_value,p_expected,p_label||' has the intended visibility');
 end if;
end $$;
set local session_replication_role = replica;
insert into private.users(id) select ('76600000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid from generate_series(1,6)g;
insert into private.roles(user_id,team_id,role) values
 ('76600000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','review-member'),
 ('76600000-0000-4000-8000-000000000004','00000000-0000-0000-0000-000000000000','review-admin'),
 ('76600000-0000-4000-8000-000000000005','76620000-0000-4000-8000-000000000001','member');
insert into public.sources(id,version,state_code,user_id,team_id,json,json_ordered,reviews)
select ('76610000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'00.00.001',
 case g when 1 then 100 when 2 then 0 when 8 then 0 when 12 then -1 else 20 end,
 '76600000-0000-4000-8000-000000000001',
 case when g=9 then '76620000-0000-4000-8000-000000000001'::uuid else null end,
 jsonb_build_object('sourceDataSet',jsonb_build_object('administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:dataSetVersion','00.00.001')))),
 jsonb_build_object('sourceDataSet',jsonb_build_object('administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:dataSetVersion','00.00.001'))))::json,
 case when g in (6,8) then '[{"id":"76630000-0000-4000-8000-000000000004"}]'::jsonb
 when g=7 then '[{"id":"76630000-0000-4000-8000-000000000005"}]'::jsonb
 when g=10 then '[{"id":"76630000-0000-4000-8000-000000000004"},{"id":"76630000-0000-4000-8000-000000000004"},{"id":null},{}]'::jsonb
 when g=11 then null else '[]'::jsonb end
from generate_series(1,12)g;
insert into private.reviews(id,data_id,data_version,state_code,reviewer_id,json)
select ('76630000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 case when g=3 then '76610000-0000-4000-8000-000000000099'::uuid else ('76610000-0000-4000-8000-'||lpad((g+2)::text,12,'0'))::uuid end,
 '00.00.001',case when g=4 then -1 else 1 end,
 case when g=5 then '["76600000-0000-4000-8000-000000000006"]'::jsonb else '["76600000-0000-4000-8000-000000000003"]'::jsonb end,
 jsonb_build_object('data',case when g=6 then '{}'::jsonb when g=7 then '{"id":null,"version":"00.00.001"}'::jsonb else
 jsonb_build_object('id',('76610000-0000-4000-8000-'||lpad((g+2)::text,12,'0'))::uuid,'version',case when g=2 then '00.00.002' else '00.00.001' end) end,
 'user',jsonb_build_object('id','76600000-0000-4000-8000-000000000001'))
from generate_series(1,7)g;
set local session_replication_role = origin;
select * from pg_temp.parity('76600000-0000-4000-8000-000000000001','owner','{"rows": [["76610000-0000-4000-8000-000000000001", "00.00.001"], ["76610000-0000-4000-8000-000000000002", "00.00.001"], ["76610000-0000-4000-8000-000000000003", "00.00.001"], ["76610000-0000-4000-8000-000000000004", "00.00.001"], ["76610000-0000-4000-8000-000000000005", "00.00.001"], ["76610000-0000-4000-8000-000000000006", "00.00.001"], ["76610000-0000-4000-8000-000000000007", "00.00.001"], ["76610000-0000-4000-8000-000000000008", "00.00.001"], ["76610000-0000-4000-8000-000000000009", "00.00.001"], ["76610000-0000-4000-8000-000000000010", "00.00.001"], ["76610000-0000-4000-8000-000000000011", "00.00.001"], ["76610000-0000-4000-8000-000000000012", "00.00.001"]]}'::jsonb);
select * from pg_temp.parity('76600000-0000-4000-8000-000000000002','outsider','{"rows": [["76610000-0000-4000-8000-000000000001", "00.00.001"], ["76610000-0000-4000-8000-000000000012", "00.00.001"]]}'::jsonb);
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','Review member','{"rows": [["76610000-0000-4000-8000-000000000001", "00.00.001"], ["76610000-0000-4000-8000-000000000003", "00.00.001"], ["76610000-0000-4000-8000-000000000005", "00.00.001"], ["76610000-0000-4000-8000-000000000006", "00.00.001"], ["76610000-0000-4000-8000-000000000010", "00.00.001"], ["76610000-0000-4000-8000-000000000012", "00.00.001"]]}'::jsonb);
select * from pg_temp.parity('76600000-0000-4000-8000-000000000004','Review admin','{"rows": [["76610000-0000-4000-8000-000000000001", "00.00.001"], ["76610000-0000-4000-8000-000000000003", "00.00.001"], ["76610000-0000-4000-8000-000000000004", "00.00.001"], ["76610000-0000-4000-8000-000000000005", "00.00.001"], ["76610000-0000-4000-8000-000000000006", "00.00.001"], ["76610000-0000-4000-8000-000000000007", "00.00.001"], ["76610000-0000-4000-8000-000000000009", "00.00.001"], ["76610000-0000-4000-8000-000000000010", "00.00.001"], ["76610000-0000-4000-8000-000000000011", "00.00.001"], ["76610000-0000-4000-8000-000000000012", "00.00.001"]]}'::jsonb);
select * from pg_temp.parity('76600000-0000-4000-8000-000000000005','team member','{"rows": [["76610000-0000-4000-8000-000000000001", "00.00.001"], ["76610000-0000-4000-8000-000000000009", "00.00.001"], ["76610000-0000-4000-8000-000000000012", "00.00.001"]]}'::jsonb);
select * from pg_temp.parity('76600000-0000-4000-8000-000000000006','assigned actor without Review role','{"rows": [["76610000-0000-4000-8000-000000000001", "00.00.001"], ["76610000-0000-4000-8000-000000000012", "00.00.001"]]}'::jsonb);
select * from pg_temp.parity(null,'absent actor','{"rows":[["76610000-0000-4000-8000-000000000001","00.00.001"]]}'::jsonb);
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','unknown OAuth client','{"rows":[]}'::jsonb,'76690000-0000-4000-8000-000000000001');
select set_config('app.review_legacy_migration','on',true);
update private.reviews set json=jsonb_set(json,'{data,id}','"malformed-uuid"') where id='76630000-0000-4000-8000-000000000003';
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','assigned malformed Review target','{"sqlstate":"22P02"}'::jsonb);
select * from pg_temp.parity('76600000-0000-4000-8000-000000000002','RLS-hidden malformed Review target','{"rows":[["76610000-0000-4000-8000-000000000001","00.00.001"],["76610000-0000-4000-8000-000000000012","00.00.001"]]}'::jsonb);
update private.reviews set json=jsonb_set(json,'{data,id}','"76610000-0000-4000-8000-000000000005"') where id='76630000-0000-4000-8000-000000000003';
set local session_replication_role = replica;
update public.sources set reviews='[{"id":"76630000-0000-4000-8000-000000000004"},{"id":"malformed-hint"}]' where id='76610000-0000-4000-8000-000000000010';
set local session_replication_role = origin;
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','malformed Source hint','{"sqlstate":"22P02"}'::jsonb);
set local session_replication_role = replica;
update public.sources set reviews='[]' where id='76610000-0000-4000-8000-000000000010';
set local session_replication_role = origin;
update private.reviews set json=jsonb_set(json,'{data,version}','{"malformed":true}') where id='76630000-0000-4000-8000-000000000003';
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','non-text Review version','{"rows":[["76610000-0000-4000-8000-000000000001","00.00.001"],["76610000-0000-4000-8000-000000000003","00.00.001"],["76610000-0000-4000-8000-000000000006","00.00.001"],["76610000-0000-4000-8000-000000000012","00.00.001"]]}'::jsonb);
set local session_replication_role = replica;
update public.sources set reviews='{}' where id='76610000-0000-4000-8000-000000000010';
set local session_replication_role = origin;
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','object hint input');
select * from pg_temp.parity('76600000-0000-4000-8000-000000000002','object hint with RLS-empty Review set');
select * from pg_temp.parity(null,'object hint with absent actor');
select * from pg_temp.parity('76600000-0000-4000-8000-000000000001','object hint owner short circuit');
select * from pg_temp.parity('76600000-0000-4000-8000-000000000004','object hint admin short circuit');
set local session_replication_role = replica;
update public.sources set reviews='"scalar"' where id='76610000-0000-4000-8000-000000000010';
set local session_replication_role = origin;
select * from pg_temp.parity('76600000-0000-4000-8000-000000000002','scalar hint with RLS-empty Review set');
select * from pg_temp.parity(null,'scalar hint with absent actor');
set local session_replication_role = replica;
update public.sources set reviews='[]' where id='76610000-0000-4000-8000-000000000010';
set local session_replication_role = origin;
update private.reviews set json=jsonb_set(json,'{data,version}','null') where id='76630000-0000-4000-8000-000000000003';
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','NULL Review version','{"rows":[["76610000-0000-4000-8000-000000000001","00.00.001"],["76610000-0000-4000-8000-000000000003","00.00.001"],["76610000-0000-4000-8000-000000000006","00.00.001"],["76610000-0000-4000-8000-000000000012","00.00.001"]]}'::jsonb);
-- A malformed assigned sibling must not create a new failure for a focused read.
-- The retained predecessor's natural hashed plan already raises 22P02 here.
update private.reviews set json=jsonb_set(json,'{data,id}','"malformed-uuid"') where id='76630000-0000-4000-8000-000000000003';
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','valid first target with malformed assigned sibling','{"sqlstate":"22P02"}'::jsonb,null,'76610000-0000-4000-8000-000000000003');
set local session_replication_role = replica;
update public.sources set reviews='[{"id":"76630000-0000-4000-8000-000000000001"}]' where id='76610000-0000-4000-8000-000000000003';
set local session_replication_role = origin;
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','valid hint plus malformed assigned sibling','{"sqlstate":"22P02"}'::jsonb,null,'76610000-0000-4000-8000-000000000003');
set local session_replication_role = replica;
create temporary table reverse_reviews as select * from private.reviews;
delete from private.reviews;
insert into private.reviews select * from reverse_reviews order by id desc;
set local session_replication_role = origin;
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','reversed Review insertion order','{"sqlstate":"22P02"}'::jsonb,null,'76610000-0000-4000-8000-000000000003');
select * from pg_temp.parity('76600000-0000-4000-8000-000000000003','published Source short circuit','{"rows":[["76610000-0000-4000-8000-000000000001","00.00.001"]]}'::jsonb,null,'76610000-0000-4000-8000-000000000001');
select * from pg_temp.parity('76600000-0000-4000-8000-000000000001','owner Source short circuit','{"rows":[["76610000-0000-4000-8000-000000000003","00.00.001"]]}'::jsonb,null,'76610000-0000-4000-8000-000000000003');
select ok((select count(*)=case when (select merged_examples from source_policy_layout) then 2 else 3 end
 from pg_policies where schemaname='public' and tablename='sources' and cmd='SELECT'),
 'Source SELECT policy layout, including example semantics and restrictive OAuth guards, restores exactly');
select set_config('app.review_legacy_migration','off',true);
select * from finish();
rollback;
