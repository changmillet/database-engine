CREATE TABLE IF NOT EXISTS "private"."result_query_release_bindings" (
    "release_run_id" "uuid" NOT NULL,
    "artifact_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "private"."result_query_release_bindings" OWNER TO "postgres";

ALTER TABLE ONLY "private"."result_query_release_bindings"
    ADD CONSTRAINT "result_query_release_bindings_pkey" PRIMARY KEY ("release_run_id");

ALTER TABLE ONLY "private"."result_query_release_bindings"
    ADD CONSTRAINT "result_query_release_bindings_artifact_id_fkey" FOREIGN KEY ("artifact_id") REFERENCES "private"."result_query_artifacts"("id") ON DELETE RESTRICT;

ALTER TABLE ONLY "private"."result_query_release_bindings"
    ADD CONSTRAINT "result_query_release_bindings_release_run_id_fkey" FOREIGN KEY ("release_run_id") REFERENCES "private"."lca_release_runs"("id") ON DELETE RESTRICT;

ALTER TABLE "private"."result_query_release_bindings" ENABLE ROW LEVEL SECURITY;
