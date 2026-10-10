CREATE OR REPLACE FUNCTION "private"."display_assert_navigation_contract_v1"() RETURNS "void"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$select private.assert_portal_navigation_contract_v1()$$;

ALTER FUNCTION "private"."display_assert_navigation_contract_v1"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_assert_navigation_contract_v1"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_assert_navigation_contract_v1"() TO "portal_display_executor";
