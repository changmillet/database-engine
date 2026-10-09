CREATE OR REPLACE FUNCTION "private"."dataset_display_require_manager"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null then raise exception using errcode='28000',message='authentication required'; end if;
  if not exists (select 1 from private.roles where user_id=auth.uid()
    and team_id='00000000-0000-0000-0000-000000000000'::uuid and role::text='data_product_manager') then
    raise exception using errcode='42501',message='data_product_manager role required';
  end if;
end; $$;

ALTER FUNCTION "private"."dataset_display_require_manager"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_display_require_manager"() FROM PUBLIC;
