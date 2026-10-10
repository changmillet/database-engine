CREATE OR REPLACE VIEW "private"."display_read_lcia_projection_headers" AS
 SELECT "id",
    "status",
    "process_count",
    "impact_count",
    "expected_value_count",
    "content_hash"
   FROM "private"."display_read_lcia_projection_headers_rows"() "display_read_lcia_projection_headers_rows"("id", "status", "process_count", "impact_count", "expected_value_count", "content_hash");

ALTER VIEW "private"."display_read_lcia_projection_headers" OWNER TO "portal_public_executor";
