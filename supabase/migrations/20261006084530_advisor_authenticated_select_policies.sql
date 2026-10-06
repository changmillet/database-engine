-- Database #785: combine only the six same-role authenticated SELECT pairs.
-- Contacts retains its PUBLIC-scoped original policy. Every restrictive policy,
-- including OAuth and Process 120 denial, remains intact.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create temp table issue785_policy_prestate on commit drop as
select p.* from pg_catalog.pg_policy p where p.polrelid in (
  'public.flowproperties'::regclass,
  'public.flows'::regclass,
  'public.lifecyclemodels'::regclass,
  'public.processes'::regclass,
  'public.sources'::regclass,
  'public.unitgroups'::regclass);
do $guard$
declare f record; p record; expected_md5 text;
begin
 for f in select * from (values
    ('flowproperties','Enable read access for authenticated users','5183e3cc87eebd2ef6e8d06402b08c2e','f733bdd17c0fce93b3a09a7664c9c1e5'),
    ('flowproperties','authenticated_example_read','3d9a81a2c1bd53264b5261e049be2365','f733bdd17c0fce93b3a09a7664c9c1e5'),
    ('flows','Enable read access for authenticated users','aa016ec3d15c1dd2dd84273f6bfe8512','908a56bed68974ae7ba2576acf1705b9'),
    ('flows','authenticated_example_read','3d9a81a2c1bd53264b5261e049be2365','908a56bed68974ae7ba2576acf1705b9'),
    ('lifecyclemodels','Enable read access for authenticated users','fb183d364096e5b6d7076b4db43fe6b4','49f6ea278baafb0db1aca7f0f700d0d7'),
    ('lifecyclemodels','authenticated_example_read','3d9a81a2c1bd53264b5261e049be2365','49f6ea278baafb0db1aca7f0f700d0d7'),
    ('processes','Enable read access for authenticated users','b05f93f87e0113757d6fb799e121f39e','f095667da5b58f05d146eceeee44d0e6'),
    ('processes','authenticated_example_read','3d9a81a2c1bd53264b5261e049be2365','f095667da5b58f05d146eceeee44d0e6'),
    ('sources','Enable read access for authenticated users','fd66eaf47f8356cf0ce80b9bf4c6915d','b7f24a21e584e0b033433e10fd301da7'),
    ('sources','authenticated_example_read','3d9a81a2c1bd53264b5261e049be2365','b7f24a21e584e0b033433e10fd301da7'),
    ('unitgroups','Enable read access for authenticated users','669efad7bbfa4e65e16c43aa5fbf7974','271cc343fcf286eed9c1a6f8f7544454'),
    ('unitgroups','authenticated_example_read','3d9a81a2c1bd53264b5261e049be2365','271cc343fcf286eed9c1a6f8f7544454')
 ) expected(table_name,policy_name,qual_md5,merged_md5) loop
  select * into p from pg_catalog.pg_policy
    where polrelid=('public.'||f.table_name)::regclass and polname=f.policy_name;
  if not found then
   if f.policy_name='authenticated_example_read' then continue; end if;
   raise exception using errcode='55000',message='Database #785 SELECT policy absent';
  end if;
  expected_md5:=f.qual_md5;
  if f.policy_name='Enable read access for authenticated users' and not exists(
    select 1 from pg_catalog.pg_policy where polrelid=p.polrelid and polname='authenticated_example_read') then
   expected_md5:=f.merged_md5;
  end if;
  if p.polcmd<>'r' or not p.polpermissive or p.polroles<>array['authenticated'::regrole::oid]
     or p.polwithcheck is not null
     or pg_catalog.md5(pg_catalog.pg_get_expr(p.polqual,p.polrelid)) is distinct from expected_md5 then
   raise exception using errcode='55000',message='Database #785 SELECT policy prestate drift';
  end if;
 end loop;
end;
$guard$;
alter policy "Enable read access for authenticated users" on public.flowproperties using ((((state_code >= 100) OR (( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = flowproperties.team_id) AND ((roles.role)::text = ANY (ARRAY[('admin'::character varying)::text, ('member'::character varying)::text, ('owner'::character varying)::text])) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR ((state_code = 20) AND ((EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = '00000000-0000-0000-0000-000000000000'::uuid) AND ((roles.role)::text = 'review-admin'::text) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.state_code > 0) AND ((((r."json" -> 'data'::text) ->> 'id'::text))::uuid = flowproperties.id) AND (((r."json" -> 'data'::text) ->> 'version'::text) = (flowproperties.version)::text) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.id IN ( SELECT ((review_item.value ->> 'id'::text))::uuid AS uuid
           FROM jsonb_array_elements(flowproperties.reviews) review_item(value))) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))))))) or (((state_code = '-1'::integer) AND (( SELECT auth.uid() AS uid) IS NOT NULL))));
drop policy if exists authenticated_example_read on public.flowproperties;
alter policy "Enable read access for authenticated users" on public.flows using ((((state_code >= 100) OR (( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = flows.team_id) AND ((roles.role)::text = ANY (ARRAY[('admin'::character varying)::text, ('member'::character varying)::text, ('owner'::character varying)::text])) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR ((state_code = 20) AND ((EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = '00000000-0000-0000-0000-000000000000'::uuid) AND ((roles.role)::text = 'review-admin'::text) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.state_code > 0) AND ((((r."json" -> 'data'::text) ->> 'id'::text))::uuid = flows.id) AND (((r."json" -> 'data'::text) ->> 'version'::text) = (flows.version)::text) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.id IN ( SELECT ((review_item.value ->> 'id'::text))::uuid AS uuid
           FROM jsonb_array_elements(flows.reviews) review_item(value))) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))))))) or (((state_code = '-1'::integer) AND (( SELECT auth.uid() AS uid) IS NOT NULL))));
drop policy if exists authenticated_example_read on public.flows;
alter policy "Enable read access for authenticated users" on public.lifecyclemodels using ((((state_code >= 100) OR (( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = lifecyclemodels.team_id) AND ((roles.role)::text = ANY (ARRAY[('admin'::character varying)::text, ('member'::character varying)::text, ('owner'::character varying)::text])) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR ((state_code = 20) AND ((EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = '00000000-0000-0000-0000-000000000000'::uuid) AND ((roles.role)::text = 'review-admin'::text) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.state_code > 0) AND ((((r."json" -> 'data'::text) ->> 'id'::text))::uuid = lifecyclemodels.id) AND (((r."json" -> 'data'::text) ->> 'version'::text) = (lifecyclemodels.version)::text) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.id IN ( SELECT ((review_item.value ->> 'id'::text))::uuid AS uuid
           FROM jsonb_array_elements(lifecyclemodels.reviews) review_item(value))) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))))))) or (((state_code = '-1'::integer) AND (( SELECT auth.uid() AS uid) IS NOT NULL))));
drop policy if exists authenticated_example_read on public.lifecyclemodels;
alter policy "Enable read access for authenticated users" on public.processes using ((((state_code >= 100) OR (( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = processes.team_id) AND ((roles.role)::text = ANY (ARRAY[('admin'::character varying)::text, ('member'::character varying)::text, ('owner'::character varying)::text])) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR ((EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = '00000000-0000-0000-0000-000000000000'::uuid) AND ((roles.role)::text = 'review-admin'::text) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.state_code > 0) AND ((((r."json" -> 'data'::text) ->> 'id'::text))::uuid = processes.id) AND (((r."json" -> 'data'::text) ->> 'version'::text) = (processes.version)::text) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.id IN ( SELECT ((review_item.value ->> 'id'::text))::uuid AS uuid
           FROM jsonb_array_elements(processes.reviews) review_item(value))) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text)))))))) or (((state_code = '-1'::integer) AND (( SELECT auth.uid() AS uid) IS NOT NULL))));
drop policy if exists authenticated_example_read on public.processes;
alter policy "Enable read access for authenticated users" on public.sources using ((((state_code >= 100) OR (( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = sources.team_id) AND ((roles.role)::text = ANY (ARRAY['admin'::text, 'member'::text, 'owner'::text])) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR ((state_code = 20) AND ((EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = '00000000-0000-0000-0000-000000000000'::uuid) AND ((roles.role)::text = 'review-admin'::text) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR ((id, (version)::text) IN ( SELECT (((r."json" -> 'data'::text) ->> 'id'::text))::uuid AS uuid,
    ((r."json" -> 'data'::text) ->> 'version'::text)
   FROM private.reviews r
  WHERE ((r.state_code > 0) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))) OR
CASE
    WHEN (EXISTS ( SELECT 1
       FROM private.reviews r
      WHERE (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text)))) THEN ((jsonb_array_length(reviews) > 0) AND (ARRAY( SELECT ((review_item.value ->> 'id'::text))::uuid AS uuid
       FROM jsonb_array_elements(sources.reviews) review_item(value)) && ( SELECT array_agg(r.id) AS array_agg
       FROM private.reviews r
      WHERE (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text)))))
    ELSE false
END)))) or (((state_code = '-1'::integer) AND (( SELECT auth.uid() AS uid) IS NOT NULL))));
drop policy if exists authenticated_example_read on public.sources;
alter policy "Enable read access for authenticated users" on public.unitgroups using ((((state_code >= 100) OR (( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = unitgroups.team_id) AND ((roles.role)::text = ANY (ARRAY[('admin'::character varying)::text, ('member'::character varying)::text, ('owner'::character varying)::text])) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR ((state_code = 20) AND ((EXISTS ( SELECT 1
   FROM private.roles
  WHERE ((roles.team_id = '00000000-0000-0000-0000-000000000000'::uuid) AND ((roles.role)::text = 'review-admin'::text) AND (roles.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.state_code > 0) AND ((((r."json" -> 'data'::text) ->> 'id'::text))::uuid = unitgroups.id) AND (((r."json" -> 'data'::text) ->> 'version'::text) = (unitgroups.version)::text) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))) OR (EXISTS ( SELECT 1
   FROM private.reviews r
  WHERE ((r.id IN ( SELECT ((review_item.value ->> 'id'::text))::uuid AS uuid
           FROM jsonb_array_elements(unitgroups.reviews) review_item(value))) AND (r.reviewer_id @> jsonb_build_array((( SELECT auth.uid() AS uid))::text))))))))) or (((state_code = '-1'::integer) AND (( SELECT auth.uid() AS uid) IS NOT NULL))));
drop policy if exists authenticated_example_read on public.unitgroups;
do $postcondition$
begin
 if exists(select 1 from issue785_policy_prestate b left join pg_catalog.pg_policy p using(oid)
   where b.polname not in('Enable read access for authenticated users','authenticated_example_read')
     and (p.oid is null or to_jsonb(b) is distinct from to_jsonb(p)))
 or exists(select 1 from issue785_policy_prestate b join pg_catalog.pg_policy p using(oid)
   where b.polname='Enable read access for authenticated users'
     and (to_jsonb(b)-'polqual') is distinct from (to_jsonb(p)-'polqual')) then
  raise exception using errcode='55000',message='Database #785 unrelated policy metadata changed';
 end if;
end;
$postcondition$;
commit;
