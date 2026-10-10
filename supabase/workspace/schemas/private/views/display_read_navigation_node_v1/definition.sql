CREATE OR REPLACE VIEW "private"."display_read_navigation_node_v1" AS
 SELECT "node_id",
    "parent_node_id",
    "code",
    "taxonomy",
    "dimension",
    "source_index_path",
    "source_file",
    "alias_codes",
    "labels",
    "label_strategy"
   FROM "private"."portal_navigation_node_v1";

ALTER VIEW "private"."display_read_navigation_node_v1" OWNER TO "portal_public_executor";
