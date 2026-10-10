CREATE OR REPLACE VIEW "private"."display_read_lcia_projection_process_axis" AS
 SELECT "projection_id",
    "process_index",
    "process_id",
    "process_version",
    "functional_unit_amount",
    "functional_unit_unit",
    "functional_unit_description",
    "geography_code",
    "geography_precision",
    "reference_year"
   FROM "private"."display_read_lcia_projection_process_axis_rows"() "display_read_lcia_projection_process_axis_rows"("projection_id", "process_index", "process_id", "process_version", "functional_unit_amount", "functional_unit_unit", "functional_unit_description", "geography_code", "geography_precision", "reference_year");

ALTER VIEW "private"."display_read_lcia_projection_process_axis" OWNER TO "portal_public_executor";
