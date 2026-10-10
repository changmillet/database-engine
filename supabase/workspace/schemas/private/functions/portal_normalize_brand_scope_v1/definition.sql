CREATE OR REPLACE FUNCTION "private"."portal_normalize_brand_scope_v1"("p_allowed_brands" "text"[]) RETURNS "text"[]
    LANGUAGE "plpgsql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare v_result text[];
begin
  if p_allowed_brands is null
    or coalesce(pg_catalog.array_ndims(p_allowed_brands), 0) <> 1
    or pg_catalog.cardinality(p_allowed_brands) not between 1 and 4
    or exists (
      select 1 from pg_catalog.unnest(p_allowed_brands) b(code)
      where code is null or code not in ('tiangong_lca', 'bafu', 'uslci', 'worldsteel')
    ) then
    raise exception using errcode = '22023', message = 'invalid portal brand scope';
  end if;
  select pg_catalog.array_agg(code order by code collate "C") into v_result
    from (select distinct code from pg_catalog.unnest(p_allowed_brands) b(code)) normalized;
  return v_result;
end;
$$;

ALTER FUNCTION "private"."portal_normalize_brand_scope_v1"("p_allowed_brands" "text"[]) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_normalize_brand_scope_v1"("p_allowed_brands" "text"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_normalize_brand_scope_v1"("p_allowed_brands" "text"[]) TO "portal_public_executor";
