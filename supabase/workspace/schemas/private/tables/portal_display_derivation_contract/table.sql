CREATE TABLE IF NOT EXISTS "private"."portal_display_derivation_contract" (
    "contract_version" smallint NOT NULL,
    "identity" "text" NOT NULL
);

ALTER TABLE "private"."portal_display_derivation_contract" OWNER TO "postgres";

ALTER TABLE ONLY "private"."portal_display_derivation_contract"
    ADD CONSTRAINT "portal_display_derivation_contract_pkey" PRIMARY KEY ("contract_version");
