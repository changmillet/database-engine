CREATE OR REPLACE FUNCTION "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select p_scope || ':~' || pg_catalog.substr(
    pg_catalog.encode(
      extensions.digest(
        pg_catalog.convert_to(p_scope || '|' || pg_catalog.upper(pg_catalog.btrim(p_code)), 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    1,
    16
  )
$$;

ALTER FUNCTION "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") TO "postgres";
