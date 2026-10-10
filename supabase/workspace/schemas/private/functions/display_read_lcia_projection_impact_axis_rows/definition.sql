CREATE OR REPLACE FUNCTION "private"."display_read_lcia_projection_impact_axis_rows"() RETURNS TABLE("projection_id" "uuid", "impact_index" integer, "method_id" "uuid", "method_version" "text", "impact_id" "text", "impact_name" "jsonb", "unit" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$select projection_id,impact_index,method_id,method_version,impact_id,impact_name,unit from private.portal_lcia_projection_impact_axis$$;

ALTER FUNCTION "private"."display_read_lcia_projection_impact_axis_rows"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_read_lcia_projection_impact_axis_rows"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_read_lcia_projection_impact_axis_rows"() TO "portal_display_executor";
