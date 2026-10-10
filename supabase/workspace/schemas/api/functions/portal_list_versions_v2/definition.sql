CREATE OR REPLACE FUNCTION "api"."portal_list_versions_v2"("p_allowed_brands" "text"[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_list_versions_v1(p_kind, p_id, p_cursor, p_limit)),'{schemaVersion}',to_jsonb('portal.public-version-page.v2'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;

ALTER FUNCTION "api"."portal_list_versions_v2"("p_allowed_brands" "text"[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "api"."portal_list_versions_v2"("p_allowed_brands" "text"[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_list_versions_v2"("p_allowed_brands" "text"[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) TO "anon";

GRANT ALL ON FUNCTION "api"."portal_list_versions_v2"("p_allowed_brands" "text"[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) TO "authenticated";
