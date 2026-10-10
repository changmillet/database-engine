CREATE OR REPLACE FUNCTION "api"."portal_sitemap_shard_v2"("p_allowed_brands" "text"[], "p_shard_cursor" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=private.display_api_sitemap_shard_v1(p_shard_cursor);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;

ALTER FUNCTION "api"."portal_sitemap_shard_v2"("p_allowed_brands" "text"[], "p_shard_cursor" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "api"."portal_sitemap_shard_v2"("p_allowed_brands" "text"[], "p_shard_cursor" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."portal_sitemap_shard_v2"("p_allowed_brands" "text"[], "p_shard_cursor" "text") TO "anon";

GRANT ALL ON FUNCTION "api"."portal_sitemap_shard_v2"("p_allowed_brands" "text"[], "p_shard_cursor" "text") TO "authenticated";
