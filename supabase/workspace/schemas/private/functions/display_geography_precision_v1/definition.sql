CREATE OR REPLACE FUNCTION "private"."display_geography_precision_v1"("p_code" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select 'unknown'::text
$$;

ALTER FUNCTION "private"."display_geography_precision_v1"("p_code" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_geography_precision_v1"("p_code" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_geography_precision_v1"("p_code" "text") TO "postgres";
