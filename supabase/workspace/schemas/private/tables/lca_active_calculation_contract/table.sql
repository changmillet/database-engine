CREATE TABLE IF NOT EXISTS "private"."lca_active_calculation_contract" (
    "singleton" boolean DEFAULT true NOT NULL,
    "fingerprint" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "lca_active_calculation_contract_singleton_check" CHECK ("singleton")
);

ALTER TABLE "private"."lca_active_calculation_contract" OWNER TO "postgres";

ALTER TABLE ONLY "private"."lca_active_calculation_contract"
    ADD CONSTRAINT "lca_active_calculation_contract_pkey" PRIMARY KEY ("singleton");

ALTER TABLE ONLY "private"."lca_active_calculation_contract"
    ADD CONSTRAINT "lca_active_calculation_contract_fingerprint_fkey" FOREIGN KEY ("fingerprint") REFERENCES "private"."lca_calculation_contracts"("fingerprint");

ALTER TABLE "private"."lca_active_calculation_contract" ENABLE ROW LEVEL SECURITY;
