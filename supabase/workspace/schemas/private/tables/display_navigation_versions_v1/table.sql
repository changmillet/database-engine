CREATE TABLE IF NOT EXISTS "private"."display_navigation_versions_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "process_id" "uuid" GENERATED ALWAYS AS (
CASE
    WHEN ("dataset_kind" = 'process'::"text") THEN "id"
    ELSE NULL::"uuid"
END) STORED,
    "process_version" "text" GENERATED ALWAYS AS (
CASE
    WHEN ("dataset_kind" = 'process'::"text") THEN "version"
    ELSE NULL::"text"
END) STORED,
    "access_level" "text" NOT NULL,
    "geography_code" "text",
    "classification_codes" "text"[] NOT NULL,
    "reference_year" integer,
    "process_subtype" "text",
    "source" "text",
    CONSTRAINT "d807_portal_navigation_versions_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"])))
);

ALTER TABLE ONLY "private"."display_navigation_versions_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_navigation_versions_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."display_navigation_versions_v1"
    ADD CONSTRAINT "d807_portal_navigation_versions_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_navigation_versions_v1"
    ADD CONSTRAINT "d807_navigation_versions_v1_dataset_kind_process_id_proc_fkey" FOREIGN KEY ("dataset_kind", "process_id", "process_version") REFERENCES "private"."display_catalog_search_rows_v2"("dataset_kind", "id", "version") ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY "private"."display_navigation_versions_v1"
    ADD CONSTRAINT "d807_rtal_navigation_versions_v1_dataset_kind_id_version_fkey" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_search_rows_v1"("dataset_kind", "id", "version") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE "private"."display_navigation_versions_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."display_navigation_versions_v1" TO "portal_display_executor";
