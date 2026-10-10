CREATE OR REPLACE FUNCTION "private"."portal_display_mode_v1"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
 select mode from private.portal_display_rollout where singleton
$$;

ALTER FUNCTION "private"."portal_display_mode_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_mode_v1"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_display_mode_v1"() TO "portal_public_executor";

GRANT ALL ON FUNCTION "private"."portal_display_mode_v1"() TO "portal_display_executor";
