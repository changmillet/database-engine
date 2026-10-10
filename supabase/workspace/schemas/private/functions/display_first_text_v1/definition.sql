CREATE OR REPLACE FUNCTION "private"."display_first_text_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select item ->> 'value'
  from jsonb_array_elements(private.display_localized_text_v1(p_value)) as localized(item)
  order by case item ->> 'language' when 'en' then 0 when 'zh' then 1 else 2 end
  limit 1
$$;

ALTER FUNCTION "private"."display_first_text_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_first_text_v1"("p_value" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_first_text_v1"("p_value" "jsonb") TO "postgres";
