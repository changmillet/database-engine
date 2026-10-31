CREATE OR REPLACE FUNCTION "private"."result_query_immutable_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if tg_table_name = 'result_query_artifacts' and tg_op = 'UPDATE' then
    if old.status = 'preparing' and new.status = 'ready'
    and (to_jsonb(old) - array['status','ready_at']) = (to_jsonb(new) - array['status','ready_at']) then
      return new;
    end if;
  end if;
  raise exception using errcode = '55000', message = 'Result query evidence is immutable';
end;
$$;

ALTER FUNCTION "private"."result_query_immutable_guard"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."result_query_immutable_guard"() FROM PUBLIC;
