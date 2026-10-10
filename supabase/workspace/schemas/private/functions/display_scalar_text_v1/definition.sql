CREATE OR REPLACE FUNCTION "private"."display_scalar_text_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case
    when jsonb_typeof(p_value) = 'string' then btrim(p_value #>> '{}')
    else null
  end
$$;

ALTER FUNCTION "private"."display_scalar_text_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_scalar_text_v1"("p_value" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_scalar_text_v1"("p_value" "jsonb") TO "postgres";
