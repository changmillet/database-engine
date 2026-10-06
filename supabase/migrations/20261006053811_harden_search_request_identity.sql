-- Bind search visibility to the actual request role across nested definers.
-- A missing legacy JWT GUC is never evidence of a trusted service request.
-- CREATE OR REPLACE preserves the existing exact signatures, owners and ACLs.

create or replace function private.dataset_search_effective_user_id(p_this_user_id text)
returns uuid
language plpgsql
stable
set search_path to 'private', 'api', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
as $$
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
$$;

create or replace function private.dataset_search_can_read_team_filter(
  p_team_id uuid,
  p_actor_id uuid
) returns boolean
language plpgsql
stable
security definer
set search_path to 'private', 'api', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
as $$
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
