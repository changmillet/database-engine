CREATE OR REPLACE FUNCTION "private"."dataset_search_effective_user_id"("p_this_user_id" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'private', 'api', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    AS $_$
declare
  v_request_role text := nullif(pg_catalog.current_setting('role', true), '');
  v_actor_id uuid;
  v_trusted_sql boolean :=
    coalesce(v_request_role, 'none') = 'none'
    and session_user = 'postgres'
    and nullif(pg_catalog.current_setting('request.jwt.claims', true), '') is null
    and nullif(pg_catalog.current_setting('request.jwt.claim.role', true), '') is null
    and nullif(pg_catalog.current_setting('request.jwt.claim.sub', true), '') is null
    and nullif(pg_catalog.current_setting('request.headers', true), '') is null
    and nullif(pg_catalog.current_setting('request.method', true), '') is null
    and nullif(pg_catalog.current_setting('request.path', true), '') is null;
begin
  if v_request_role = 'authenticated' then
    begin
      return auth.uid();
    exception when invalid_text_representation then
      return null::uuid;
    end;
  end if;

  if v_request_role is distinct from 'service_role' and not v_trusted_sql then
    return null::uuid;
  end if;

  -- Explicit service-role requests retain their actor-first compatibility.
  begin
    v_actor_id := auth.uid();
  exception when invalid_text_representation then
    return null::uuid;
  end;
  if v_actor_id is not null then
    return v_actor_id;
  end if;

  return case
    when coalesce(btrim(p_this_user_id) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
      then btrim(p_this_user_id)::uuid
    else null::uuid
  end;
end;
$_$;

ALTER FUNCTION "private"."dataset_search_effective_user_id"("p_this_user_id" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_search_effective_user_id"("p_this_user_id" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."dataset_search_effective_user_id"("p_this_user_id" "text") TO "api_internal_executor";
