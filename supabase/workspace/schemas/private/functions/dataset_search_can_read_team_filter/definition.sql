CREATE OR REPLACE FUNCTION "private"."dataset_search_can_read_team_filter"("p_team_id" "uuid", "p_actor_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'private', 'api', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    AS $$
declare
  v_request_role text := nullif(pg_catalog.current_setting('role', true), '');
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
  if p_team_id is null then
    return false;
  end if;

  if v_request_role = 'service_role' or v_trusted_sql then
    return true;
  end if;

  if v_request_role is distinct from 'authenticated'
     or p_actor_id is null
     or p_actor_id is distinct from private.dataset_search_effective_user_id('') then
    return false;
  end if;

  return exists (
    select 1
    from private.roles r
    where r.team_id = p_team_id
      and r.user_id = p_actor_id
      and r.role::text in ('admin', 'member', 'owner')
  );
end;
$$;

ALTER FUNCTION "private"."dataset_search_can_read_team_filter"("p_team_id" "uuid", "p_actor_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_search_can_read_team_filter"("p_team_id" "uuid", "p_actor_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."dataset_search_can_read_team_filter"("p_team_id" "uuid", "p_actor_id" "uuid") TO "api_internal_executor";
