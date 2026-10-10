CREATE TABLE IF NOT EXISTS "private"."portal_display_contract_manifest" (
    "singleton" boolean NOT NULL,
    "identity" "text" NOT NULL,
    CONSTRAINT "portal_display_contract_manifest_singleton_check" CHECK ("singleton")
);

ALTER TABLE "private"."portal_display_contract_manifest" OWNER TO "postgres";

ALTER TABLE ONLY "private"."portal_display_contract_manifest"
    ADD CONSTRAINT "portal_display_contract_manifest_pkey" PRIMARY KEY ("singleton");
