CREATE TABLE IF NOT EXISTS "private"."result_query_artifacts" (
    "id" "uuid" NOT NULL,
    "package_id" "uuid" NOT NULL,
    "artifact_ref" "jsonb" NOT NULL,
    "manifest" "jsonb" NOT NULL,
    "process_count" integer NOT NULL,
    "impact_count" integer NOT NULL,
    "status" "text" DEFAULT 'preparing'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ready_at" timestamp with time zone,
    CONSTRAINT "result_query_artifacts_check" CHECK ((("status" = 'ready'::"text") = ("ready_at" IS NOT NULL))),
    CONSTRAINT "result_query_artifacts_check1" CHECK ((("jsonb_typeof"("artifact_ref") = 'object'::"text") AND ("jsonb_typeof"("manifest") = 'object'::"text"))),
    CONSTRAINT "result_query_artifacts_impact_count_check" CHECK ((("impact_count" >= 0) AND ("impact_count" <= 4096))),
    CONSTRAINT "result_query_artifacts_process_count_check" CHECK ((("process_count" >= 1) AND ("process_count" <= 2000000))),
    CONSTRAINT "result_query_artifacts_status_check" CHECK (("status" = ANY (ARRAY['preparing'::"text", 'ready'::"text"])))
);

ALTER TABLE "private"."result_query_artifacts" OWNER TO "postgres";

ALTER TABLE ONLY "private"."result_query_artifacts"
    ADD CONSTRAINT "result_query_artifacts_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "private"."result_query_artifacts"
    ADD CONSTRAINT "result_query_artifacts_package_id_fkey" FOREIGN KEY ("package_id") REFERENCES "private"."lcia_result_packages"("id") ON DELETE RESTRICT;

ALTER TABLE "private"."result_query_artifacts" ENABLE ROW LEVEL SECURITY;
