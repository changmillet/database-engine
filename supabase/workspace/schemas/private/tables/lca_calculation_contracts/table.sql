CREATE TABLE IF NOT EXISTS "private"."lca_calculation_contracts" (
    "fingerprint" "text" NOT NULL,
    "descriptor" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "lca_calculation_contracts_descriptor_check" CHECK ((("octet_length"("descriptor") >= 2) AND ("octet_length"("descriptor") <= 16384))),
    CONSTRAINT "lca_calculation_contracts_fingerprint_check" CHECK (("fingerprint" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "lca_calculation_descriptor_hash" CHECK (("fingerprint" = "encode"("extensions"."digest"("descriptor", 'sha256'::"text"), 'hex'::"text"))),
    CONSTRAINT "lca_calculation_descriptor_object" CHECK (("jsonb_typeof"(("descriptor")::"jsonb") = 'object'::"text"))
);

ALTER TABLE "private"."lca_calculation_contracts" OWNER TO "postgres";

ALTER TABLE ONLY "private"."lca_calculation_contracts"
    ADD CONSTRAINT "lca_calculation_contracts_pkey" PRIMARY KEY ("fingerprint");

ALTER TABLE "private"."lca_calculation_contracts" ENABLE ROW LEVEL SECURITY;
