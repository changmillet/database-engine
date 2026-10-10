CREATE OR REPLACE FUNCTION "api"."portal_search_flows_v4"("p_allowed_brands" "text"[], "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_search_flows_v3(p_query, p_filters - 'brand', p_sort, p_cursor, p_limit)),'{schemaVersion}',to_jsonb('portal.public-search-page.v3'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;

ALTER FUNCTION "api"."portal_search_flows_v4"("p_allowed_brands" "text"[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "api"."portal_search_flows_v4"("p_allowed_brands" "text"[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_search_flows_v4"("p_allowed_brands" "text"[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) TO "anon";

GRANT ALL ON FUNCTION "api"."portal_search_flows_v4"("p_allowed_brands" "text"[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) TO "authenticated";
