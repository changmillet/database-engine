CREATE OR REPLACE FUNCTION "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select nullif(pg_catalog.btrim(coalesce(
    p_card #>> '{geography,code}',
    case when p_kind = 'flow' then p_card #>> '{geography,locationOfSupply}' end
  )), '')
$$;

ALTER FUNCTION "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") TO "postgres";
