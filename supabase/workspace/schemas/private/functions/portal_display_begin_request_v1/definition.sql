CREATE OR REPLACE FUNCTION "private"."portal_display_begin_request_v1"("p_allowed_brands" "text"[], "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare b text[]:=private.portal_normalize_brand_scope_v1(p_allowed_brands); f text;
begin
 if (select mode from private.portal_display_rollout where singleton) is distinct from 'display' then
  raise exception using errcode='P0001',message='portal catalog unavailable';
 end if;
 if p_filters ? 'brand' then
  f:=p_filters->>'brand';
  if jsonb_typeof(p_filters->'brand') is distinct from 'string'
   or f is null or f not in ('tiangong_lca','bafu','uslci','worldsteel') then
   raise exception using errcode='22023',message='invalid portal request';
  end if;
 end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands',array_to_string(b,','),true);
 perform set_config('portal.display_global','false',true);
 perform set_config('portal.display_filter_brand',coalesce(f,''),true);
end $$;

ALTER FUNCTION "private"."portal_display_begin_request_v1"("p_allowed_brands" "text"[], "p_filters" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_begin_request_v1"("p_allowed_brands" "text"[], "p_filters" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_display_begin_request_v1"("p_allowed_brands" "text"[], "p_filters" "jsonb") TO "portal_display_executor";
