CREATE OR REPLACE FUNCTION "private"."display_read_lcia_projection_values_rows"() RETURNS TABLE("projection_id" "uuid", "ordinal" bigint, "process_index" integer, "impact_index" integer, "value_text" "text", "value_numeric" numeric)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$select projection_id,ordinal,process_index,impact_index,value_text,value_numeric from private.portal_lcia_projection_values$$;

ALTER FUNCTION "private"."display_read_lcia_projection_values_rows"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_read_lcia_projection_values_rows"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_read_lcia_projection_values_rows"() TO "portal_display_executor";
