CREATE TABLE IF NOT EXISTS "private"."display_navigation_membership_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "dimension" "text" NOT NULL,
    "node_id" "text" NOT NULL,
    "direct" boolean NOT NULL,
    CONSTRAINT "d807_portal_navigation_membership_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_navigation_membership_v1_dimension_check" CHECK (("dimension" = ANY (ARRAY['classification'::"text", 'geography'::"text"]))),
    CONSTRAINT "d807_portal_navigation_membership_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_navigation_membership_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_navigation_membership_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."display_navigation_membership_v1"
    ADD CONSTRAINT "d807_portal_navigation_membership_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version", "dimension", "node_id");

ALTER TABLE ONLY "private"."display_navigation_membership_v1"
    ADD CONSTRAINT "d807_al_navigation_membership_v1_dataset_kind_id_version_fkey" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_navigation_versions_v1"("dataset_kind", "id", "version") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "private"."display_navigation_membership_v1"
    ADD CONSTRAINT "d807_portal_navigation_membership_v1_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "private"."portal_navigation_node_v1"("node_id") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."display_navigation_membership_v1" ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE "private"."display_navigation_membership_v1" TO "portal_display_executor";
