CREATE OR REPLACE FUNCTION "private"."lcia_category_availability_valid_v1"("p_receipt" "jsonb", "p_require_complete" boolean DEFAULT false) RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
declare
  v_category jsonb;
  v_reason jsonb;
  v_text text;
  v_previous text;
  v_index integer := 0;
  v_available integer := 0;
  v_identity text;
  v_identities text[] := '{}'::text[];
  v_completeness text;
begin
  if jsonb_typeof(p_receipt) is distinct from 'object' then return false; end if;
  if not p_receipt ?& array['schema_version','policy_version','completeness','categories']
     or (select count(*) from jsonb_object_keys(p_receipt)) <> 4
     or p_receipt->>'schema_version' is distinct from 'lcia.category-availability.v1'
     or p_receipt->>'policy_version' is distinct from 'lcia.applicability.source-bound.v3'
     or jsonb_typeof(p_receipt->'categories') is distinct from 'array' then
    return false;
  end if;
  if jsonb_array_length(p_receipt->'categories') not between 1 and 256 then return false; end if;
  for v_category in select value from jsonb_array_elements(p_receipt->'categories') loop
    if jsonb_typeof(v_category) is distinct from 'object' then return false; end if;
    if not v_category ?& array['impact_index','method_id','method_version','status','reasons']
       or (select count(*) from jsonb_object_keys(v_category)) <> 5
       or jsonb_typeof(v_category->'impact_index') is distinct from 'number'
       or v_category->>'impact_index' is distinct from v_index::text
       or jsonb_typeof(v_category->'method_id') is distinct from 'string'
       or v_category->>'method_id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or jsonb_typeof(v_category->'method_version') is distinct from 'string'
       or v_category->>'method_version' !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
       or coalesce(v_category->>'status','') not in ('available','unavailable')
       or jsonb_typeof(v_category->'reasons') is distinct from 'array' then
      return false;
    end if;
    v_identity := (v_category->>'method_id') || ':' || (v_category->>'method_version');
    if v_identity = any(v_identities) then return false; end if;
    v_identities := array_append(v_identities, v_identity);
    if jsonb_array_length(v_category->'reasons') > 32
       or ((v_category->>'status' = 'available') <> (jsonb_array_length(v_category->'reasons') = 0)) then
      return false;
    end if;
    v_previous := null;
    for v_reason in select value from jsonb_array_elements(v_category->'reasons') loop
      if jsonb_typeof(v_reason) is distinct from 'string' then return false; end if;
      v_text := v_reason #>> '{}';
      if v_text !~ '^[a-z0-9_]{1,160}$'
         or (v_previous is not null and v_previous collate "C" >= v_text collate "C") then
        return false;
      end if;
      v_previous := v_text;
    end loop;
    if v_category->>'status' = 'available' then v_available := v_available + 1; end if;
    v_index := v_index + 1;
  end loop;
  v_completeness := case when v_available = v_index then 'complete'
    when v_available = 0 then 'unavailable' else 'partial' end;
  return p_receipt->>'completeness' is not distinct from v_completeness
    and (not coalesce(p_require_complete, false) or v_completeness = 'complete');
end
$_$;

ALTER FUNCTION "private"."lcia_category_availability_valid_v1"("p_receipt" "jsonb", "p_require_complete" boolean) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_category_availability_valid_v1"("p_receipt" "jsonb", "p_require_complete" boolean) FROM PUBLIC;
