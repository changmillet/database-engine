CREATE OR REPLACE VIEW "private"."display_read_navigation_contract_v1" AS
 SELECT "contract_version",
    "asset_sha256"
   FROM "private"."portal_navigation_contract_v1";

ALTER VIEW "private"."display_read_navigation_contract_v1" OWNER TO "portal_public_executor";
