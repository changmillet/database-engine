CREATE OR REPLACE FUNCTION "private"."portal_display_request_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
 select exists(select 1 from private.dataset_display_settings s
 where s.dataset_kind=p_kind and s.dataset_id=p_id and s.dataset_version=p_version
 and s.is_visible and
 (current_setting('portal.display_global',true)='true' or
 s.brand=any(string_to_array(current_setting('portal.display_brands',true),',')))
 and (nullif(current_setting('portal.display_filter_brand',true),'') is null or
 s.brand=current_setting('portal.display_filter_brand',true)))
$$;

ALTER FUNCTION "private"."portal_display_request_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_request_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_display_request_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") TO "portal_display_executor";
