CREATE TABLE IF NOT EXISTS "private"."display_catalog_search_rows_v2" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "card" "jsonb" NOT NULL,
    "document" "text" NOT NULL,
    "projection_contract_version" smallint NOT NULL,
    "brand" "text",
    CONSTRAINT "d807_portal_catalog_search_rows_contract_version_v2_chk" CHECK (("projection_contract_version" = 2)),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_card_check" CHECK (("jsonb_typeof"("card") = 'object'::"text")),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = 'process'::"text")),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text")),
    CONSTRAINT "d807_portal_catalog_search_rows_v2_check" CHECK ((COALESCE(("card" ->> 'document'::"text"), ''::"text") = "document")),
    CONSTRAINT "display_catalog_search_rows_v2_brand_check" CHECK ((("brand" IS NULL) OR ("brand" = ANY (ARRAY['tiangong_lca'::"text", 'bafu'::"text", 'uslci'::"text", 'worldsteel'::"text"]))))
);

ALTER TABLE ONLY "private"."display_catalog_search_rows_v2" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_catalog_search_rows_v2" OWNER TO "postgres";

COMMENT ON TABLE "private"."display_catalog_search_rows_v2" IS 'Private synchronized, public-safe Portal card/document projection. Source embeddings and HNSW indexes remain authoritative and are not duplicated.';

ALTER TABLE ONLY "private"."display_catalog_search_rows_v2"
    ADD CONSTRAINT "d807_portal_catalog_search_rows_v2_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_catalog_search_rows_v2"
    ADD CONSTRAINT "d807_portal_catalog_search_rows_contract_version_v2_fk" FOREIGN KEY ("projection_contract_version") REFERENCES "private"."portal_display_derivation_contract"("contract_version") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."display_catalog_search_rows_v2" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."display_catalog_search_rows_v2" TO "portal_display_executor";
