CREATE OR REPLACE FUNCTION "private"."lca_calculation_contract_is_current"("p_fingerprint" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select fingerprint is null or fingerprint is not distinct from p_fingerprint
  from private.lca_active_calculation_contract where singleton;
$$;

ALTER FUNCTION "private"."lca_calculation_contract_is_current"("p_fingerprint" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lca_calculation_contract_is_current"("p_fingerprint" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."lca_calculation_contract_is_current"("p_fingerprint" "text") TO "service_role";

GRANT ALL ON FUNCTION "private"."lca_calculation_contract_is_current"("p_fingerprint" "text") TO "api_internal_executor";
