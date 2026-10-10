CREATE OR REPLACE FUNCTION "api"."portal_flow_link_eligibility_v1"("p_allowed_brands" "text"[], "p_flow_refs" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare b text[]:=private.portal_normalize_brand_scope_v1(p_allowed_brands); result jsonb;
begin
 if (select mode from private.portal_display_rollout where singleton) is distinct from 'display' then
  raise exception using errcode='P0001',message='portal catalog unavailable';
 end if;
 if jsonb_typeof(p_flow_refs) is distinct from 'array' or jsonb_array_length(p_flow_refs)>50
 or exists(select 1 from jsonb_array_elements(p_flow_refs) r where
  private.portal_lcia_json_object_has_keys_v1(r,array['id','version']) is not true
  or coalesce(r->>'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  or coalesce(r->>'version','') !~ '^\d{2}\.\d{2}\.\d{3}$') then
  raise exception using errcode='22023',message='invalid portal request';
 end if;
 perform private.portal_display_assert_contract_v1();
 select coalesce(jsonb_agg(jsonb_build_object('id',r->>'id','version',r->>'version','linkable',
  private.portal_dataset_in_brand_scope_v1('flow',(r->>'id')::uuid,r->>'version',b)
  and exists(select 1 from private.display_catalog_search_rows_v1 p
   where p.dataset_kind='flow' and p.id=(r->>'id')::uuid and p.version=r->>'version')) order by ord),'[]')
 into result from jsonb_array_elements(p_flow_refs) with ordinality x(r,ord);
 return result;
end $_$;

ALTER FUNCTION "api"."portal_flow_link_eligibility_v1"("p_allowed_brands" "text"[], "p_flow_refs" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."portal_flow_link_eligibility_v1"("p_allowed_brands" "text"[], "p_flow_refs" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_flow_link_eligibility_v1"("p_allowed_brands" "text"[], "p_flow_refs" "jsonb") TO "anon";

GRANT ALL ON FUNCTION "api"."portal_flow_link_eligibility_v1"("p_allowed_brands" "text"[], "p_flow_refs" "jsonb") TO "authenticated";
