CREATE TABLE IF NOT EXISTS "private"."result_query_sources" (
    "artifact_id" "uuid" NOT NULL,
    "process_id" "uuid" NOT NULL,
    "process_version" "text" NOT NULL,
    "row_ordinal" integer NOT NULL,
    CONSTRAINT "result_query_sources_process_version_check" CHECK (("process_version" ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'::"text")),
    CONSTRAINT "result_query_sources_row_ordinal_check" CHECK (("row_ordinal" >= 0))
);

ALTER TABLE "private"."result_query_sources" OWNER TO "postgres";

ALTER TABLE ONLY "private"."result_query_sources"
    ADD CONSTRAINT "result_query_sources_artifact_id_row_ordinal_key" UNIQUE ("artifact_id", "row_ordinal");

ALTER TABLE ONLY "private"."result_query_sources"
    ADD CONSTRAINT "result_query_sources_pkey" PRIMARY KEY ("artifact_id", "process_id", "process_version");

ALTER TABLE ONLY "private"."result_query_sources"
    ADD CONSTRAINT "result_query_sources_artifact_id_fkey" FOREIGN KEY ("artifact_id") REFERENCES "private"."result_query_artifacts"("id") ON DELETE RESTRICT;

ALTER TABLE "private"."result_query_sources" ENABLE ROW LEVEL SECURITY;
