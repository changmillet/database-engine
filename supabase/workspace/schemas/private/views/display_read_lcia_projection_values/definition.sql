CREATE OR REPLACE VIEW "private"."display_read_lcia_projection_values" AS
 SELECT "projection_id",
    "ordinal",
    "process_index",
    "impact_index",
    "value_text",
    "value_numeric"
   FROM "private"."display_read_lcia_projection_values_rows"() "display_read_lcia_projection_values_rows"("projection_id", "ordinal", "process_index", "impact_index", "value_text", "value_numeric");

ALTER VIEW "private"."display_read_lcia_projection_values" OWNER TO "portal_public_executor";
