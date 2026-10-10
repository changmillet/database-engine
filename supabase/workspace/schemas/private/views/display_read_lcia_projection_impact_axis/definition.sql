CREATE OR REPLACE VIEW "private"."display_read_lcia_projection_impact_axis" AS
 SELECT "projection_id",
    "impact_index",
    "method_id",
    "method_version",
    "impact_id",
    "impact_name",
    "unit"
   FROM "private"."display_read_lcia_projection_impact_axis_rows"() "display_read_lcia_projection_impact_axis_rows"("projection_id", "impact_index", "method_id", "method_version", "impact_id", "impact_name", "unit");

ALTER VIEW "private"."display_read_lcia_projection_impact_axis" OWNER TO "portal_public_executor";
