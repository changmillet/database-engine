CREATE OR REPLACE VIEW "private"."display_read_lcia_projection_publications" AS
 SELECT "id",
    "projection_id",
    "lcia_result_publication_id",
    "package_id",
    "package_version",
    "projection_content_hash",
    "evidence_hash",
    "source_published_at",
    "status",
    "revoked_at"
   FROM "private"."display_read_lcia_projection_publications_rows"() "display_read_lcia_projection_publications_rows"("id", "projection_id", "lcia_result_publication_id", "package_id", "package_version", "projection_content_hash", "evidence_hash", "source_published_at", "status", "revoked_at");

ALTER VIEW "private"."display_read_lcia_projection_publications" OWNER TO "portal_public_executor";
