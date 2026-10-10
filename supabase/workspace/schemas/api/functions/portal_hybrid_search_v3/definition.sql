CREATE OR REPLACE FUNCTION "api"."portal_hybrid_search_v3"("p_allowed_brands" "text"[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_hybrid_search_v2(p_kind, p_query_terms, p_query_embedding, p_filters - 'brand', p_limit, p_cursor)),'{schemaVersion}',to_jsonb('portal.public-hybrid-candidate-page.v3'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;

ALTER FUNCTION "api"."portal_hybrid_search_v3"("p_allowed_brands" "text"[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "api"."portal_hybrid_search_v3"("p_allowed_brands" "text"[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_hybrid_search_v3"("p_allowed_brands" "text"[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") TO "anon";

GRANT ALL ON FUNCTION "api"."portal_hybrid_search_v3"("p_allowed_brands" "text"[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") TO "authenticated";
