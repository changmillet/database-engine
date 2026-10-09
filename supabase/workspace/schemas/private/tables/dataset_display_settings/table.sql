CREATE TABLE IF NOT EXISTS "private"."dataset_display_settings" (
    "dataset_kind" "text" NOT NULL,
    "dataset_id" "uuid" NOT NULL,
    "dataset_version" character(9) NOT NULL,
    "is_visible" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dataset_display_settings_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['lifecyclemodel'::"text", 'process'::"text", 'flow'::"text", 'flowproperty'::"text", 'unitgroup'::"text", 'source'::"text", 'contact'::"text"]))),
    CONSTRAINT "dataset_display_settings_dataset_version_check" CHECK (("dataset_version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE "private"."dataset_display_settings" OWNER TO "postgres";

COMMENT ON TABLE "private"."dataset_display_settings" IS 'Exact-version list visibility only. Missing configuration is hidden; no actor or history is stored. Does not confer raw, export, Portal, calculation or numerical publication access.';

ALTER TABLE ONLY "private"."dataset_display_settings"
    ADD CONSTRAINT "dataset_display_settings_pkey" PRIMARY KEY ("dataset_kind", "dataset_id", "dataset_version");

ALTER TABLE "private"."dataset_display_settings" ENABLE ROW LEVEL SECURITY;
