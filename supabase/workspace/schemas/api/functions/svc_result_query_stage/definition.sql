CREATE OR REPLACE FUNCTION "api"."svc_result_query_stage"("p_package_id" "uuid", "p_artifact_ref" "jsonb", "p_manifest" "jsonb", "p_rows" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;

ALTER FUNCTION "api"."svc_result_query_stage"("p_package_id" "uuid", "p_artifact_ref" "jsonb", "p_manifest" "jsonb", "p_rows" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_result_query_stage"("p_package_id" "uuid", "p_artifact_ref" "jsonb", "p_manifest" "jsonb", "p_rows" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."svc_result_query_stage"("p_package_id" "uuid", "p_artifact_ref" "jsonb", "p_manifest" "jsonb", "p_rows" "jsonb") TO "service_role";
