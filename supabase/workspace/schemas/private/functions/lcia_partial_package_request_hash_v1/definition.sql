CREATE OR REPLACE FUNCTION "private"."lcia_partial_package_request_hash_v1"("p_job" "private"."worker_jobs") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
begin
  return encode(extensions.digest(convert_to(jsonb_build_array(
    'lcia.private-partial-ready.request.v1',p_job.id,p_job.job_kind,p_job.worker_runtime,
    p_job.worker_queue,p_job.subject_type,p_job.subject_id,p_job.subject_version,
    p_job.requested_by,p_job.team_id,p_job.payload_schema_version,p_job.payload_json
  )::text,'UTF8'),'sha256'),'hex');
end
$$;

ALTER FUNCTION "private"."lcia_partial_package_request_hash_v1"("p_job" "private"."worker_jobs") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_partial_package_request_hash_v1"("p_job" "private"."worker_jobs") FROM PUBLIC;
