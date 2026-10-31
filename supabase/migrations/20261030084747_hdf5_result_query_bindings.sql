begin;

-- Numeric values remain in immutable S3 objects. These relations hold only
-- verified encoding identity, source ordinals and a binding to the existing
-- formal release. They do not create another current-publication pointer.
create table private.result_query_artifacts (
  id uuid primary key,
  package_id uuid not null references private.lcia_result_packages(id) on delete restrict,
  artifact_ref jsonb not null,
  manifest jsonb not null,
  process_count integer not null check (process_count between 1 and 2000000),
  impact_count integer not null check (impact_count between 0 and 4096),
  status text not null default 'preparing' check (status in ('preparing', 'ready')),
  created_at timestamptz not null default now(),
  ready_at timestamptz,
  check ((status = 'ready') = (ready_at is not null)),
  check (jsonb_typeof(artifact_ref) = 'object' and jsonb_typeof(manifest) = 'object')
);
create index result_query_artifacts_package_idx on private.result_query_artifacts(package_id);

create table private.result_query_sources (
  artifact_id uuid not null references private.result_query_artifacts(id) on delete restrict,
  process_id uuid not null,
  process_version text not null check (process_version ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'),
  row_ordinal integer not null check (row_ordinal >= 0),
  primary key (artifact_id, process_id, process_version),
  unique (artifact_id, row_ordinal)
);

create table private.result_query_release_bindings (
  release_run_id uuid primary key references private.lca_release_runs(id) on delete restrict,
  artifact_id uuid not null references private.result_query_artifacts(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index result_query_release_bindings_artifact_idx
  on private.result_query_release_bindings(artifact_id);

alter table private.result_query_artifacts enable row level security;
alter table private.result_query_sources enable row level security;
alter table private.result_query_release_bindings enable row level security;
revoke all on private.result_query_artifacts, private.result_query_sources,
  private.result_query_release_bindings from public, anon, authenticated, service_role;

create function private.result_query_immutable_guard() returns trigger
language plpgsql set search_path = '' as $$
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
revoke all on function private.result_query_immutable_guard() from public, anon, authenticated, service_role;
create trigger result_query_artifacts_immutable before update or delete on private.result_query_artifacts
  for each row execute function private.result_query_immutable_guard();
create trigger result_query_sources_immutable before update or delete on private.result_query_sources
  for each row execute function private.result_query_immutable_guard();
create trigger result_query_release_bindings_immutable before update or delete on private.result_query_release_bindings
  for each row execute function private.result_query_immutable_guard();

-- Called only by the trusted publisher after verifying the manifest, compressed
-- index hash and every HDF5 file. A bounded retry may repeat exact rows, never
-- change an identity. The database independently binds the canonical Bundle.
create function api.svc_result_query_stage(
  p_package_id uuid, p_artifact_ref jsonb, p_manifest jsonb, p_rows jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_package private.lcia_result_packages%rowtype;
  v_existing private.result_query_artifacts%rowtype;
  v_bundle jsonb;
  v_id uuid;
  v_row record;
  v_old private.result_query_sources%rowtype;
begin
  if jsonb_typeof(p_artifact_ref) is distinct from 'object'
    or jsonb_typeof(p_manifest) is distinct from 'object'
    or jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception using errcode='22023', message='Invalid query artifact input';
  end if;
  if pg_column_size(p_manifest) > 1048576 or pg_column_size(p_rows) > 1048576
    or jsonb_array_length(p_rows) not between 1 and 500
    or p_artifact_ref->>'schemaVersion' is distinct from 'tiangong.query-artifact.v1'
    or p_manifest->>'schemaVersion' is distinct from 'tiangong.query-artifact.v1'
    or coalesce(p_artifact_ref->>'manifestSha256','') !~ '^[0-9a-f]{64}$'
    or coalesce((p_artifact_ref->>'manifestByteSize')::bigint,0) not between 1 and 1048576
    or p_manifest->>'artifactId' is distinct from p_artifact_ref->>'artifactId'
    or coalesce((p_manifest->>'processCount')::integer,0) not between 1 and 2000000
    or coalesce((p_manifest->>'impactCount')::integer,-1) not between 0 and 4096 then
    raise exception using errcode='22023', message='Invalid query artifact contract';
  end if;
  v_id := (p_artifact_ref->>'artifactId')::uuid;
  select * into v_package from private.lcia_result_packages where id=p_package_id for share;
  if not found or v_package.status <> 'preview_ready' then
    raise exception using errcode='22023', message='Ready source package required';
  end if;
  select coalesce(v_package.artifact_manifest->'calculationBundle', result.diagnostics->'calculation_bundle')
    into v_bundle from private.lca_results result where result.id=v_package.result_id;
  if v_bundle is null or v_bundle->>'schemaVersion' is distinct from 'tiangong.calculation-bundle.v2'
    or p_manifest#>>'{source,schemaVersion}' is distinct from v_bundle->>'schemaVersion'
    or p_manifest#>>'{source,calculationId}' is distinct from v_bundle->>'calculationId'
    or p_manifest#>>'{source,bundleContentHash}' is distinct from v_bundle->>'bundleContentHash'
    or p_manifest#>>'{source,manifestSha256}' is distinct from v_bundle->>'manifestSha256'
    or coalesce(v_bundle->>'bundleContentHash','') !~ '^[0-9a-f]{64}$'
    or coalesce(v_bundle->>'manifestSha256','') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023', message='Query artifact source Bundle mismatch';
  end if;
  -- Serializes same-artifact retries including first registration.
  perform pg_advisory_xact_lock(hashtextextended(v_id::text, 877));
  select * into v_existing from private.result_query_artifacts where id=v_id for update;
  if found then
    if v_existing.package_id <> p_package_id or v_existing.artifact_ref <> p_artifact_ref
      or v_existing.manifest <> p_manifest then
      raise exception using errcode='22023', message='Query artifact identity conflict';
    end if;
  else
    insert into private.result_query_artifacts(id,package_id,artifact_ref,manifest,process_count,impact_count)
      values(v_id,p_package_id,p_artifact_ref,p_manifest,(p_manifest->>'processCount')::integer,
        (p_manifest->>'impactCount')::integer);
  end if;
  for v_row in select * from jsonb_to_recordset(p_rows) as row(id uuid,version text,ordinal integer)
  loop
    if v_row.id is null or coalesce(v_row.version,'') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
      or v_row.ordinal is null or v_row.ordinal < 0 or v_row.ordinal >= (p_manifest->>'processCount')::integer then
      raise exception using errcode='22023', message='Invalid query source row';
    end if;
    select * into v_old from private.result_query_sources
      where artifact_id=v_id and (row_ordinal=v_row.ordinal or (process_id=v_row.id and process_version=v_row.version));
    if found then
      if v_old.row_ordinal <> v_row.ordinal or v_old.process_id <> v_row.id or v_old.process_version <> v_row.version then
        raise exception using errcode='22023', message='Query source row conflict';
      end if;
    elsif v_existing.status = 'ready' then
      raise exception using errcode='55000', message='Ready query artifact is immutable';
    else
      insert into private.result_query_sources values(v_id,v_row.id,v_row.version,v_row.ordinal);
    end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('artifactId',v_id,
    'registeredProcessCount',(select count(*) from private.result_query_sources where artifact_id=v_id)));
end;
$$;

create function api.svc_result_query_seal(p_artifact_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_artifact private.result_query_artifacts%rowtype;
  v_package private.lcia_result_packages%rowtype;
begin
  select * into v_artifact from private.result_query_artifacts where id=p_artifact_id for update;
  if not found then raise exception using errcode='22023',message='Query artifact not found'; end if;
  select * into v_package from private.lcia_result_packages where id=v_artifact.package_id for share;
  if v_package.status <> 'preview_ready'
    or (select count(*) from private.result_query_sources where artifact_id=p_artifact_id) <> v_artifact.process_count
    or jsonb_typeof(v_package.input_manifest->'processes') is distinct from 'array' then
    raise exception using errcode='22023',message='Query source axis incomplete';
  end if;
  if jsonb_array_length(v_package.input_manifest->'processes') <> v_package.included_input_count
    or v_package.included_input_count < 1
    or exists (select 1 from jsonb_array_elements(v_package.input_manifest->'processes') p
    where not exists(select 1 from private.result_query_sources s where s.artifact_id=p_artifact_id
      and s.process_id::text=p->>'id' and s.process_version=p->>'version')) then
    raise exception using errcode='22023',message='Query source axis does not cover package';
  end if;
  if v_artifact.status <> 'ready' then
    update private.result_query_artifacts set status='ready',ready_at=now() where id=p_artifact_id;
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('artifactId',p_artifact_id,'status','ready'));
end;
$$;

create function api.svc_result_query_bind_release(p_release_run_id uuid,p_artifact_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_run private.lca_release_runs%rowtype;
  v_artifact private.result_query_artifacts%rowtype;
  v_previous uuid;
begin
  select * into v_run from private.lca_release_runs where id=p_release_run_id for update;
  select * into v_artifact from private.result_query_artifacts where id=p_artifact_id for share;
  if v_run.id is null or v_artifact.id is null or v_artifact.status <> 'ready'
    or v_run.status not in ('ready_for_approval','approved','published','readback_verified')
    or v_run.calculation_bundle_hash is distinct from v_artifact.manifest#>>'{source,bundleContentHash}'
    or v_run.calculation_bundle_ref->>'calculationId' is distinct from v_artifact.manifest#>>'{source,calculationId}'
    or v_run.calculation_bundle_ref->>'manifestSha256' is distinct from v_artifact.manifest#>>'{source,manifestSha256}'
    or v_run.release_manifest_hash is null then
    raise exception using errcode='22023',message='Release/query Bundle binding mismatch';
  end if;
  if not exists(select 1 from private.lca_release_dataset_versions where release_run_id=v_run.id and dataset_role='unit_process')
    or exists(select 1 from private.lca_release_dataset_versions d where d.release_run_id=v_run.id and d.dataset_role='unit_process'
      and not exists(select 1 from private.result_query_sources s where s.artifact_id=p_artifact_id
        and s.process_id=d.source_process_uuid and s.process_version=d.source_process_version)) then
    raise exception using errcode='22023',message='Query artifact does not cover release roots';
  end if;
  select artifact_id into v_previous from private.result_query_release_bindings where release_run_id=p_release_run_id;
  if found and v_previous <> p_artifact_id then
    raise exception using errcode='22023',message='Release query binding is immutable';
  end if;
  insert into private.result_query_release_bindings(release_run_id,artifact_id)
    values(p_release_run_id,p_artifact_id) on conflict(release_run_id) do nothing;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('releaseRunId',p_release_run_id,'artifactId',p_artifact_id));
end;
$$;

-- Edge authenticates the user and reads the exact process through actor RLS
-- before calling this service-only descriptor. Every call independently checks
-- the formal release state and subset; file presence grants no authorization.
create function api.svc_result_query_resolve(
  p_process_id uuid,p_process_version text,p_publication_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_data jsonb;
begin
  if p_process_id is null or coalesce(p_process_version,'') !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$' then
    raise exception using errcode='22023',message='Exact process identity required';
  end if;
  select jsonb_build_object(
    'publicationId',publication.id,'releaseRunId',run.id,'releaseVersion',run.release_version,
    'publishedAt',publication.published_at,'artifact',artifact.artifact_ref,
    'process',jsonb_build_object('id',p_process_id,'version',p_process_version),
    'lciAvailable',true,'lciaAvailable',artifact.impact_count>0)
    into v_data
  from private.lca_release_publications publication
  join private.lca_release_runs run on run.id=publication.release_run_id
  join private.result_query_release_bindings binding on binding.release_run_id=run.id
  join private.result_query_artifacts artifact on artifact.id=binding.artifact_id and artifact.status='ready'
  join private.lcia_result_packages package on package.id=artifact.package_id and package.status='preview_ready'
  join private.result_query_sources source on source.artifact_id=artifact.id
    and source.process_id=p_process_id and source.process_version=p_process_version
  join private.lca_release_dataset_versions member on member.release_run_id=run.id
    and member.dataset_role='unit_process' and member.source_process_uuid=p_process_id
    and member.source_process_version=p_process_version
  where publication.is_current and publication.status='current'
    and publication.visibility_scope='public' and publication.publication_channel='public'
    and publication.publication_series_key='global'
    and run.status='readback_verified'
    and publication.release_manifest_hash=run.release_manifest_hash
    and (p_publication_id is null or publication.id=p_publication_id);
  if v_data is null then
    return jsonb_build_object('ok',false,'status',404,'code','published_result_not_available');
  end if;
  return jsonb_build_object('ok',true,'data',v_data);
end;
$$;

revoke all on function api.svc_result_query_stage(uuid,jsonb,jsonb,jsonb),
  api.svc_result_query_seal(uuid), api.svc_result_query_bind_release(uuid,uuid),
  api.svc_result_query_resolve(uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function api.svc_result_query_stage(uuid,jsonb,jsonb,jsonb),
  api.svc_result_query_seal(uuid), api.svc_result_query_bind_release(uuid,uuid),
  api.svc_result_query_resolve(uuid,text,uuid) to service_role;
insert into private.api_capability_grants
  (routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role)
values
 ('api.svc_result_query_stage(uuid, jsonb, jsonb, jsonb)','EDGE-DATA-PRODUCT-01',false,false,true),
 ('api.svc_result_query_seal(uuid)','EDGE-DATA-PRODUCT-01',false,false,true),
 ('api.svc_result_query_bind_release(uuid, uuid)','EDGE-DATA-PRODUCT-01',false,false,true),
 ('api.svc_result_query_resolve(uuid, text, uuid)','EDGE-DATA-PRODUCT-01',false,false,true);
notify pgrst,'reload schema';
commit;
