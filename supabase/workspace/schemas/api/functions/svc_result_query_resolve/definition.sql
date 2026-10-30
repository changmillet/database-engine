CREATE OR REPLACE FUNCTION "api"."svc_result_query_resolve"("p_process_id" "uuid", "p_process_version" "text", "p_publication_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;

ALTER FUNCTION "api"."svc_result_query_resolve"("p_process_id" "uuid", "p_process_version" "text", "p_publication_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_result_query_resolve"("p_process_id" "uuid", "p_process_version" "text", "p_publication_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."svc_result_query_resolve"("p_process_id" "uuid", "p_process_version" "text", "p_publication_id" "uuid") TO "service_role";
