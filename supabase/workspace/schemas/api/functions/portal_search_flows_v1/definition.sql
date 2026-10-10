CREATE OR REPLACE FUNCTION "api"."portal_search_flows_v1"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_search_flows_v1(p_query, p_filters, p_sort, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return private.portal_decorate_card_context_v1(
    private.portal_search_v1(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "api"."portal_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "api"."portal_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) TO "anon";

GRANT ALL ON FUNCTION "api"."portal_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) TO "authenticated";
