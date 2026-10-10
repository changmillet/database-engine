CREATE OR REPLACE FUNCTION "private"."portal_display_transition_v1"("p_expected" "text", "p_next" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare current_mode text;
begin
 select mode into current_mode from private.portal_display_rollout where singleton for update;
 if current_mode is distinct from p_expected or p_next is null or p_next not in ('display','unavailable') then
  raise exception using errcode='55000',message='invalid display rollout transition';
 end if;
 perform private.portal_display_assert_contract_v1();
 if p_next='display' and exists(
  select 1 from private.dataset_display_settings s
  join (select 'process'::text as kind,id,version::text as version,json,modified_at,state_code from public.processes
   union all select 'flow',id,version::text,json,modified_at,state_code from public.flows) r
   on (r.kind,r.id,r.version)=(s.dataset_kind,s.dataset_id,s.dataset_version::text)
  left join private.display_catalog_search_rows_v1 p on (p.dataset_kind,p.id,p.version)=(r.kind,r.id,r.version)
  where s.is_visible and jsonb_typeof(r.json->case r.kind when 'process' then 'processDataSet' else 'flowDataSet' end)='object'
   and (p.id is null or p.brand is distinct from s.brand or p.modified_at is distinct from r.modified_at
    or p.state_code is distinct from r.state_code
    or p.card is distinct from private.display_catalog_projection_payload_v1(r.kind,r.state_code,r.json)->'card'
    or (r.kind='process' and not exists(select 1 from private.display_catalog_search_rows_v2 c
     where c.dataset_kind=r.kind and c.id=r.id and c.version=r.version and c.brand is not distinct from s.brand
     and c.modified_at=r.modified_at and c.state_code=r.state_code
     and c.card=private.display_catalog_projection_payload_cn1(r.kind,r.state_code,r.json)->'card')))
 ) then raise exception using errcode='55000',message='display projection repair required'; end if;
 update private.portal_display_rollout set mode=p_next,changed_at=clock_timestamp() where singleton;
end $$;

ALTER FUNCTION "private"."portal_display_transition_v1"("p_expected" "text", "p_next" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_transition_v1"("p_expected" "text", "p_next" "text") FROM PUBLIC;
