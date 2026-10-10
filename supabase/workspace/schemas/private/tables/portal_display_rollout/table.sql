CREATE TABLE IF NOT EXISTS "private"."portal_display_rollout" (
    "singleton" boolean DEFAULT true NOT NULL,
    "mode" "text" NOT NULL,
    "changed_at" timestamp with time zone DEFAULT "clock_timestamp"() NOT NULL,
    CONSTRAINT "portal_display_rollout_mode_check" CHECK (("mode" = ANY (ARRAY['legacy'::"text", 'display'::"text", 'unavailable'::"text"]))),
    CONSTRAINT "portal_display_rollout_singleton_check" CHECK ("singleton")
);

ALTER TABLE "private"."portal_display_rollout" OWNER TO "postgres";

ALTER TABLE ONLY "private"."portal_display_rollout"
    ADD CONSTRAINT "portal_display_rollout_pkey" PRIMARY KEY ("singleton");
