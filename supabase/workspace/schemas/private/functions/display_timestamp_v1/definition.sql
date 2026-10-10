CREATE OR REPLACE FUNCTION "private"."display_timestamp_v1"("p_value" timestamp with time zone) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select to_char(p_value at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

ALTER FUNCTION "private"."display_timestamp_v1"("p_value" timestamp with time zone) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_timestamp_v1"("p_value" timestamp with time zone) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_timestamp_v1"("p_value" timestamp with time zone) TO "postgres";
