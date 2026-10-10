-- Database #807: additive brand and scope primitives. No public-reader cutover,
-- business-data initialization, account matching or state-code backfill.
begin;

alter table private.dataset_display_settings
  add column brand text,
  add constraint dataset_display_settings_brand_check
    check (brand in ('tiangong_lca', 'bafu', 'uslci', 'worldsteel'));
comment on column private.dataset_display_settings.brand is
  'Exact-version data brand. NULL is unassigned, not Tiangong. Deployment selection does not mutate this value or is_visible.';

create function private.dataset_display_settings_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.is_visible, new.brand) is distinct from (old.is_visible, old.brand) then
    new.updated_at := pg_catalog.clock_timestamp();
  end if;
  return new;
end;
$$;
alter function private.dataset_display_settings_touch() owner to postgres;
revoke all on function private.dataset_display_settings_touch() from public, anon, authenticated, service_role;
create trigger dataset_display_settings_touch
  before update of is_visible, brand on private.dataset_display_settings
  for each row execute function private.dataset_display_settings_touch();

create function private.portal_normalize_brand_scope_v1(p_allowed_brands text[])
returns text[] language plpgsql immutable parallel safe set search_path = '' as $$
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
alter function private.portal_normalize_brand_scope_v1(text[]) owner to postgres;
revoke all on function private.portal_normalize_brand_scope_v1(text[]) from public, anon, authenticated, service_role;
grant execute on function private.portal_normalize_brand_scope_v1(text[]) to portal_public_executor;

create function private.portal_brand_v1(p_brand text) returns jsonb
language sql immutable parallel safe set search_path = '' as $$
  select case p_brand
    when 'tiangong_lca' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'Tiangong LCA')
    when 'bafu' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'BAFU')
    when 'uslci' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'USLCI')
    when 'worldsteel' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'World steel')
    else null
  end;
$$;
alter function private.portal_brand_v1(text) owner to postgres;
revoke all on function private.portal_brand_v1(text) from public, anon, authenticated, service_role;
grant execute on function private.portal_brand_v1(text) to portal_public_executor;

-- Narrow internal policy predicate, not a public DTO reader. The exact source
-- existence, rollout mode, license, reference and publication checks belong to
-- the calling reader. This helper never exposes settings or actor identities.
create function private.portal_dataset_is_visible_v1(p_kind text, p_id uuid, p_version text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.dataset_display_settings s
    where s.dataset_kind = p_kind and s.dataset_id = p_id
      and s.dataset_version = p_version::character(9)
      and s.is_visible and p_version ~ '^\d{2}\.\d{2}\.\d{3}$'
  );
$$;
alter function private.portal_dataset_is_visible_v1(text,uuid,text) owner to postgres;
revoke all on function private.portal_dataset_is_visible_v1(text,uuid,text) from public, anon, authenticated, service_role;
grant execute on function private.portal_dataset_is_visible_v1(text,uuid,text) to portal_public_executor;

create function private.portal_dataset_in_brand_scope_v1(p_kind text, p_id uuid, p_version text, p_allowed_brands text[])
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_scope text[] := private.portal_normalize_brand_scope_v1(p_allowed_brands);
begin
  return exists (
    select 1 from private.dataset_display_settings s
    where s.dataset_kind = p_kind and s.dataset_id = p_id
      and s.dataset_version = p_version::character(9)
      and s.is_visible and s.brand = any(v_scope)
      and p_version ~ '^\d{2}\.\d{2}\.\d{3}$'
  );
end;
$$;
alter function private.portal_dataset_in_brand_scope_v1(text,uuid,text,text[]) owner to postgres;
revoke all on function private.portal_dataset_in_brand_scope_v1(text,uuid,text,text[]) from public, anon, authenticated, service_role;
grant execute on function private.portal_dataset_in_brand_scope_v1(text,uuid,text,text[]) to portal_public_executor;

commit;
