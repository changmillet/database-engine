CREATE OR REPLACE VIEW "private"."display_catalog_search_current_v2" WITH ("security_invoker"='true') AS
 SELECT "display_catalog_search_rows_v2"."dataset_kind",
    "display_catalog_search_rows_v2"."id",
    "display_catalog_search_rows_v2"."version",
    "display_catalog_search_rows_v2"."state_code",
    "display_catalog_search_rows_v2"."modified_at",
    "display_catalog_search_rows_v2"."card",
    "display_catalog_search_rows_v2"."document"
   FROM "private"."display_catalog_search_rows_v2"
  WHERE ("display_catalog_search_rows_v2"."dataset_kind" = 'process'::"text")
UNION ALL
 SELECT "display_catalog_search_rows_v1"."dataset_kind",
    "display_catalog_search_rows_v1"."id",
    "display_catalog_search_rows_v1"."version",
    "display_catalog_search_rows_v1"."state_code",
    "display_catalog_search_rows_v1"."modified_at",
    "display_catalog_search_rows_v1"."card",
    "display_catalog_search_rows_v1"."document"
   FROM "private"."display_catalog_search_rows_v1"
  WHERE ("display_catalog_search_rows_v1"."dataset_kind" = 'flow'::"text");

ALTER VIEW "private"."display_catalog_search_current_v2" OWNER TO "postgres";
