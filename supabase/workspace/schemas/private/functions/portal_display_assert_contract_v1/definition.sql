CREATE OR REPLACE FUNCTION "private"."portal_display_assert_contract_v1"() RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if (select identity from private.portal_display_contract_manifest where singleton) is distinct from private.portal_display_contract_identity_v1() then
  raise exception using errcode='P0001',message='portal catalog unavailable';
 end if;
end $$;

ALTER FUNCTION "private"."portal_display_assert_contract_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_assert_contract_v1"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_display_assert_contract_v1"() TO "portal_display_executor";

GRANT ALL ON FUNCTION "private"."portal_display_assert_contract_v1"() TO "portal_public_executor";
