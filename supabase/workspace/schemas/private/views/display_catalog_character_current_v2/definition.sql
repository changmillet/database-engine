CREATE OR REPLACE VIEW "private"."display_catalog_character_current_v2" WITH ("security_invoker"='true') AS
 SELECT "display_catalog_character_rows_v2"."dataset_kind",
    "display_catalog_character_rows_v2"."id",
    "display_catalog_character_rows_v2"."version",
    "display_catalog_character_rows_v2"."state_code",
    "display_catalog_character_rows_v2"."modified_at",
    "display_catalog_character_rows_v2"."document_characters",
    "display_catalog_character_rows_v2"."name_characters",
    "display_catalog_character_rows_v2"."name_exact_characters",
    "display_catalog_character_rows_v2"."classification_characters",
    "display_catalog_character_rows_v2"."classification_exact_characters"
   FROM "private"."display_catalog_character_rows_v2"
  WHERE ("display_catalog_character_rows_v2"."dataset_kind" = 'process'::"text")
UNION ALL
 SELECT "display_catalog_character_rows_v1"."dataset_kind",
    "display_catalog_character_rows_v1"."id",
    "display_catalog_character_rows_v1"."version",
    "display_catalog_character_rows_v1"."state_code",
    "display_catalog_character_rows_v1"."modified_at",
    "display_catalog_character_rows_v1"."document_characters",
    "display_catalog_character_rows_v1"."name_characters",
    "display_catalog_character_rows_v1"."name_exact_characters",
    "display_catalog_character_rows_v1"."classification_characters",
    "display_catalog_character_rows_v1"."classification_exact_characters"
   FROM "private"."display_catalog_character_rows_v1"
  WHERE ("display_catalog_character_rows_v1"."dataset_kind" = 'flow'::"text");

ALTER VIEW "private"."display_catalog_character_current_v2" OWNER TO "postgres";
