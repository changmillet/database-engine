CREATE TABLE IF NOT EXISTS "private"."display_sitemap_rows_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "shard_no" smallint NOT NULL,
    "contract_version" smallint NOT NULL,
    CONSTRAINT "d807_portal_sitemap_rows_v1_contract_version_check" CHECK (("contract_version" = 1)),
    CONSTRAINT "d807_portal_sitemap_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_sitemap_rows_v1_shard_no_check" CHECK ((("shard_no" >= 0) AND ("shard_no" <= 63))),
    CONSTRAINT "d807_portal_sitemap_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_sitemap_rows_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_sitemap_rows_v1" OWNER TO "postgres";

COMMENT ON TABLE "private"."display_sitemap_rows_v1" IS 'Exact public Process/Flow version and stable 64-way sitemap bucket; contains no card, document, actor, credential, or locator.';

ALTER TABLE ONLY "private"."display_sitemap_rows_v1"
    ADD CONSTRAINT "d807_portal_sitemap_rows_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_sitemap_rows_v1"
    ADD CONSTRAINT "d807_portal_sitemap_rows_source_v1_fk" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_facet_rows_v1"("dataset_kind", "id", "version") ON UPDATE RESTRICT ON DELETE CASCADE;

ALTER TABLE "private"."display_sitemap_rows_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."display_sitemap_rows_v1" TO "portal_display_executor";
