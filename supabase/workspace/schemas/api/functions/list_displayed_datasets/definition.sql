CREATE OR REPLACE FUNCTION "api"."list_displayed_datasets"("p_dataset_kind" "text" DEFAULT 'all'::"text", "p_query" "text" DEFAULT ''::"text", "p_page_size" integer DEFAULT 20, "p_page" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '15s'
    AS $$
  select private.dataset_display_list(p_dataset_kind,'visible',p_query,p_page_size,p_page,false);
$$;

ALTER FUNCTION "api"."list_displayed_datasets"("p_dataset_kind" "text", "p_query" "text", "p_page_size" integer, "p_page" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."list_displayed_datasets"("p_dataset_kind" "text", "p_query" "text", "p_page_size" integer, "p_page" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."list_displayed_datasets"("p_dataset_kind" "text", "p_query" "text", "p_page_size" integer, "p_page" integer) TO "authenticated";

GRANT ALL ON FUNCTION "api"."list_displayed_datasets"("p_dataset_kind" "text", "p_query" "text", "p_page_size" integer, "p_page" integer) TO "api_internal_executor";
