CREATE OR REPLACE FUNCTION "api"."portal_facets_v4"("p_allowed_brands" "text"[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=private.portal_display_brand_facets_v1(jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_facets_v3(p_kind, p_query, p_filters - 'brand')),'{schemaVersion}',to_jsonb('portal.public-facets.v3'::text)),p_kind,p_query,p_filters - 'brand');
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;

ALTER FUNCTION "api"."portal_facets_v4"("p_allowed_brands" "text"[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "api"."portal_facets_v4"("p_allowed_brands" "text"[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_facets_v4"("p_allowed_brands" "text"[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb") TO "anon";

GRANT ALL ON FUNCTION "api"."portal_facets_v4"("p_allowed_brands" "text"[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb") TO "authenticated";
