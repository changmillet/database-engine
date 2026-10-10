CREATE OR REPLACE FUNCTION "private"."portal_display_scope_identity_v1"() RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
 select 'portal-display-scope.v1:' || coalesce(current_setting('portal.display_brands',true),'')
 || ':global=' || coalesce(current_setting('portal.display_global',true),'false')
 || ':filter=' || coalesce(current_setting('portal.display_filter_brand',true),'')
$$;

ALTER FUNCTION "private"."portal_display_scope_identity_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_scope_identity_v1"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_display_scope_identity_v1"() TO "portal_display_executor";
