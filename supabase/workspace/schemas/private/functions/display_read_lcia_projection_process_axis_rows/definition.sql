CREATE OR REPLACE FUNCTION "private"."display_read_lcia_projection_process_axis_rows"() RETURNS TABLE("projection_id" "uuid", "process_index" integer, "process_id" "uuid", "process_version" "text", "functional_unit_amount" "text", "functional_unit_unit" "text", "functional_unit_description" "jsonb", "geography_code" "text", "geography_precision" "text", "reference_year" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$select projection_id,process_index,process_id,process_version,functional_unit_amount,functional_unit_unit,functional_unit_description,geography_code,geography_precision,reference_year from private.portal_lcia_projection_process_axis$$;

ALTER FUNCTION "private"."display_read_lcia_projection_process_axis_rows"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_read_lcia_projection_process_axis_rows"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_read_lcia_projection_process_axis_rows"() TO "portal_display_executor";
