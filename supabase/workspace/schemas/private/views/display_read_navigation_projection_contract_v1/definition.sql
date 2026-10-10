CREATE OR REPLACE VIEW "private"."display_read_navigation_projection_contract_v1" AS
 SELECT "routine_identity",
    "definition_sha256",
    "owner_name"
   FROM "private"."portal_navigation_projection_contract_v1";

ALTER VIEW "private"."display_read_navigation_projection_contract_v1" OWNER TO "portal_public_executor";
