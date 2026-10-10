CREATE OR REPLACE FUNCTION "private"."display_navigation_classification_label_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select nullif(
    pg_catalog.btrim(coalesce(
      p_value ->> '#text',
      p_value #>> '{label,0,value}'
    )),
    ''
  )
$$;

ALTER FUNCTION "private"."display_navigation_classification_label_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_classification_label_v1"("p_value" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_navigation_classification_label_v1"("p_value" "jsonb") TO "postgres";
