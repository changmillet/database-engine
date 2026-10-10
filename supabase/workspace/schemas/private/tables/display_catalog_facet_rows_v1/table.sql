CREATE TABLE IF NOT EXISTS "private"."display_catalog_facet_rows_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "facet_access_level" "text",
    "facet_geography" "text",
    "facet_reference_year" "text",
    "facet_process_subtype" "text",
    "facet_source" "text",
    "facet_contract_version" smallint NOT NULL,
    CONSTRAINT "d807_portal_catalog_facet_rows_contract_version_v1_chk" CHECK (("facet_contract_version" = 1)),
    CONSTRAINT "d807_portal_catalog_facet_rows_process_subtype_v1_chk" CHECK ((("dataset_kind" = 'process'::"text") OR ("facet_process_subtype" IS NULL))),
    CONSTRAINT "d807_portal_catalog_facet_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_catalog_facet_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_catalog_facet_rows_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_facet_rows_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_facet_rows_contract_version_v1_fk" FOREIGN KEY ("facet_contract_version") REFERENCES "private"."portal_display_derivation_contract"("contract_version") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_facet_rows_projection_v1_fk" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_search_rows_v1"("dataset_kind", "id", "version") ON UPDATE RESTRICT ON DELETE CASCADE;

ALTER TABLE "private"."display_catalog_facet_rows_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."display_catalog_facet_rows_v1" TO "portal_display_executor";
