begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

create function pg_temp.availability(p_kind text default 'partial') returns jsonb
language sql immutable as $$
select jsonb_build_object(
  'schema_version','lcia.category-availability.v1',
  'policy_version','lcia.applicability.source-bound.v3',
  'completeness',p_kind,
  'categories',jsonb_build_array(
    jsonb_build_object('impact_index',0,'method_id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'method_version','01.00.000','status',case when p_kind='unavailable' then 'unavailable' else 'available' end,
      'reasons',case when p_kind='unavailable' then '["lcia_factor_location_semantics_unresolved"]'::jsonb else '[]'::jsonb end),
    jsonb_build_object('impact_index',1,'method_id','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'method_version','02.00.000','status',case when p_kind='complete' then 'available' else 'unavailable' end,
      'reasons',case when p_kind='complete' then '[]'::jsonb else '["lcia_factor_location_semantics_unresolved"]'::jsonb end)
  ));
$$;
select ok(private.lcia_category_availability_valid_v1(pg_temp.availability(),false),'partial receipt is valid private evidence');
select ok(not private.lcia_category_availability_valid_v1(pg_temp.availability(),true),'partial receipt cannot authorize complete LCIA');
select ok(private.lcia_category_availability_valid_v1(pg_temp.availability('complete'),true),'complete exact receipt can pass the completeness predicate');
select ok(private.lcia_category_availability_valid_v1(pg_temp.availability('unavailable'),false),'all-unavailable receipt remains valid private evidence');
select ok(not private.lcia_category_availability_valid_v1(null,false),'missing receipt fails closed');
select ok(not private.lcia_category_availability_valid_v1('[]',false),'wrong JSON type fails closed');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{completeness}','"complete"'),false),'claimed completeness must equal category status');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{policy_version}','"old"'),false),'stale policy is not current receipt evidence');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{policy_version}','"lcia.applicability.source-bound.v2"'),false),'retired unbounded-generic policy cannot authorize current category availability');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{categories,1,impact_index}','1.0'),false),'index must retain integer wire representation');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{categories,1,method_id}','"not-a-uuid"'),false),'non UUID method identity is rejected');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{categories,1,method_version}','"v2"'),false),'exact ILCD method version is mandatory');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{categories,1,reasons}','["b","a"]'),false),'reason codes have canonical ordering');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{categories,1,reasons}','["a","a"]'),false),'duplicate reasons are rejected');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{categories,1,reasons}','[]'),false),'unavailable category needs an explicit reason');
select ok(not private.lcia_category_availability_valid_v1(jsonb_set(pg_temp.availability(),'{categories,1,reasons}','["not a code"]'),false),'arbitrary prose cannot enter a reason code');
select ok(not private.lcia_category_availability_valid_v1(pg_temp.availability() || '{"extra":true}',false),'unknown receipt authority is rejected');
select is((select expected_validator_scanner_fingerprint from private.lcia_scope_closure_config where singleton),
  'scope-closure-validator-scanner.v1+cutoff-readiness-r7','new admission uses r7 instead of selecting a completed r5/r6 numerical snapshot');

select ok(not has_function_privilege('authenticated','private.lcia_category_availability_valid_v1(jsonb,boolean)','execute'),'browser cannot execute private receipt helper');
select ok(not has_function_privilege('service_role','private.lcia_package_availability_valid_v1(uuid,boolean)','execute'),'service cannot invoke an internal publication predicate as a facade');
select ok(has_function_privilege('service_role','private.cmd_lcia_result_package_mark_ready(uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb)','execute'),'existing private ready signature remains service callable');
select ok(not has_function_privilege('service_role','private.lcia_package_mark_ready_before_category_availability_v1(uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb)','execute'),'preserved implementation is owner only');

select ok(has_function_privilege('service_role','private.svc_lcia_result_package_partial_mark_ready_v1(uuid,uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb)','execute'),'explicit leased partial callback is service callable');
select ok(not has_function_privilege('authenticated','private.svc_lcia_result_package_partial_mark_ready_v1(uuid,uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb)','execute'),'browser cannot call the private partial callback');
select ok(not has_function_privilege('authenticated','private.svc_lcia_result_package_ready_readback_v1(uuid,uuid)','execute'),'browser cannot recover private Worker readiness directly');

insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_sso_user,is_anonymous)
values('00000000-0000-0000-0000-000000000000','83400000-0000-4000-8000-000000000001','authenticated','authenticated','partial-lcia@example.com','test-only',now(),'{"provider":"email","providers":["email"]}','{}',now(),now(),false,false);
insert into private.users(id,raw_user_meta_data,contact)
values('83400000-0000-4000-8000-000000000001','{"email":"partial-lcia@example.com"}',null);
insert into private.teams(id,json,rank,is_public)
values('00000000-0000-0000-0000-000000000000','{"name":"System Team"}',0,false) on conflict(id) do nothing;
insert into private.roles(user_id,team_id,role)
values('83400000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','data_product_manager');

create function pg_temp.case_id(p_case integer,p_role integer) returns uuid
language sql immutable as $$ select ('83400000-0000-4000-8000-'||lpad((p_case*10+p_role)::text,12,'0'))::uuid $$;
create function pg_temp.insert_private_case(p_case integer,p_kind text) returns uuid
language plpgsql as $$
declare
  v_receipt jsonb := pg_temp.availability(p_kind);
  v_bundle jsonb;
  v_available jsonb;
  v_package uuid;
begin
  v_bundle := jsonb_build_object('schemaVersion',case when p_kind='complete' then 'tiangong.calculation-bundle.v2' else 'tiangong.calculation-bundle.v3' end,
    'calculationId',pg_temp.case_id(p_case,2),'bundleContentHash',repeat('a',64),'manifestSha256',repeat('b',64),'manifestUrl','s3://lca_results/test/manifest.json','manifestByteSize',100,'artifactCount',3);
  select coalesce(jsonb_agg(c->'method_id' order by ordinality),'[]'::jsonb) into v_available
    from jsonb_array_elements(v_receipt->'categories') with ordinality as categories(c,ordinality) where c->>'status'='available';
  insert into private.worker_jobs(id,job_kind,worker_queue,requester_type,requested_by,status,payload_schema_version,payload_json)
    values(pg_temp.case_id(p_case,1),'lcia_result.package_build','solver','user','83400000-0000-4000-8000-000000000001','completed','lcia_result.package_build.request.v1','{}');
  insert into private.lca_network_snapshots(id,scope,status,process_filter)
    values(pg_temp.case_id(p_case,3),'full_library','ready',jsonb_build_object('lcia_applicability_policy_version','lcia.applicability.source-bound.v3','lcia_availability',v_receipt));
  insert into private.lca_results(id,job_id,snapshot_id,diagnostics,worker_job_id,artifact_url,artifact_sha256,artifact_byte_size,artifact_format)
    values(pg_temp.case_id(p_case,4),pg_temp.case_id(p_case,2),pg_temp.case_id(p_case,3),jsonb_build_object('lcia_availability',v_receipt,'calculation_bundle',v_bundle),pg_temp.case_id(p_case,1),'s3://lca_results/test/result',repeat('c',64),100,'hdf5:v1');
  insert into private.lcia_result_packages(id,build_id,build_worker_job_id,package_version,coverage_mode,eligibility_resolved_at,eligible_input_count,included_input_count,input_manifest_hash,input_manifest,snapshot_id,result_id,result_artifact_ref,artifact_manifest,package_result_hash,available_impact_categories,default_impact_category,status,created_by)
    values(pg_temp.case_id(p_case,5),pg_temp.case_id(p_case,2),pg_temp.case_id(p_case,1),'01.00.'||lpad(p_case::text,3,'0'),'subset',now(),1,1,repeat('d',64),'{}',pg_temp.case_id(p_case,3),pg_temp.case_id(p_case,4),jsonb_build_object('artifactSha256',repeat('c',64)),jsonb_build_object('lciaAvailability',v_receipt,'calculationBundle',v_bundle),repeat('c',64),v_available,v_available->>0,'preview_ready','83400000-0000-4000-8000-000000000001') returning id into v_package;
  return v_package;
end $$;
select lives_ok($$select pg_temp.insert_private_case(1,'partial')$$,'private partial package retains preview readiness');
select lives_ok($$select pg_temp.insert_private_case(2,'unavailable')$$,'all-unavailable private package retains LCI readiness without a numeric default');
select lives_ok($$select pg_temp.insert_private_case(3,'complete')$$,'complete private package retains exact receipt');
select ok(private.lcia_package_availability_valid_v1(pg_temp.case_id(1,5),false),'registered private partial package validates');
select ok(not private.lcia_package_availability_valid_v1(pg_temp.case_id(1,5),true),'the same package cannot establish complete publication');
select is((select default_impact_category from private.lcia_result_packages where id=pg_temp.case_id(2,5)),null::text,'all-unavailable default is absent instead of zero or first category');
select throws_ok($$insert into private.lcia_result_publications(package_id,is_current,status) values(pg_temp.case_id(1,5),true,'current')$$,'23514','lcia_complete_result_required','partial package cannot become a public LCIA publication');
select throws_ok($$insert into private.lcia_result_publications(package_id,is_current,status) values(pg_temp.case_id(2,5),true,'current')$$,'23514','lcia_complete_result_required','all-unavailable package cannot become a public LCIA publication');
select lives_ok($$insert into private.lcia_result_publications(package_id,is_current,status) values(pg_temp.case_id(3,5),true,'current')$$,'complete registered package can pass this additive publication guard');

update private.lca_results set diagnostics=jsonb_set(diagnostics,'{lcia_availability}',pg_temp.availability('complete')) where id=pg_temp.case_id(1,4);
select ok(not private.lcia_package_availability_valid_v1(pg_temp.case_id(1,5),false),'caller and result claims cannot override a different frozen snapshot receipt');
update private.lca_results set diagnostics=jsonb_set(diagnostics,'{lcia_availability}',pg_temp.availability()) where id=pg_temp.case_id(1,4);
update private.lca_network_snapshots set process_filter=jsonb_set(process_filter,'{lcia_applicability_policy_version}','"old"') where id=pg_temp.case_id(1,3);
select ok(not private.lcia_package_availability_valid_v1(pg_temp.case_id(1,5),false),'stale snapshot policy is rejected even when result and package receipts match');
update private.lca_network_snapshots set process_filter=jsonb_set(process_filter,'{lcia_applicability_policy_version}','"lcia.applicability.source-bound.v3"') where id=pg_temp.case_id(1,3);

create function pg_temp.insert_projection(p_case integer) returns void
language plpgsql as $$ begin
  insert into private.portal_lcia_projection_headers(id,build_worker_job_id,stage_lease_token,projection_contract_version,status,process_count,impact_count,input_manifest_hash,closure_certificate_hash,snapshot_hash,closure_bundle_hash,snapshot_index_sha256,snapshot_build_contract_hash,bundle_content_hash,bundle_manifest_sha256,lcia_chunk_set_sha256,result_artifact_sha256,query_artifact_sha256)
  values(pg_temp.case_id(p_case,6),pg_temp.case_id(p_case,1),'83400000-0000-4000-8000-000000000099','portal.lcia-projection.v1','staging',1,2,repeat('d',64),repeat('d',64),repeat('d',64),repeat('d',64),repeat('d',64),repeat('d',64),repeat('a',64),repeat('b',64),repeat('d',64),repeat('c',64),repeat('d',64));
end $$;
select throws_ok($$select pg_temp.insert_projection(1)$$,'23514','lcia_complete_result_required','partial result cannot start a full Portal projection');
select throws_ok($$select pg_temp.insert_projection(2)$$,'23514','lcia_complete_result_required','all-unavailable result cannot start a full Portal projection');
select lives_ok($$select pg_temp.insert_projection(3)$$,'complete registered result passes the added Portal staging guard');
select throws_ok($$insert into private.portal_lcia_projection_publications(projection_id,lcia_result_publication_id,package_id,package_version,package_result_hash,projection_content_hash,evidence_hash,source_published_at,idempotency_key,finalized_by,finalized_at) values(pg_temp.case_id(3,6),'83400000-0000-4000-8000-000000000090',pg_temp.case_id(1,5),'01.00.001',repeat('c',64),repeat('d',64),repeat('d',64),now(),'partial-forgery','83400000-0000-4000-8000-000000000001',now())$$,'23514','lcia_complete_result_required','a complete other projection cannot publish a partial package');

create function pg_temp.prepare_release(p_case integer) returns void
language plpgsql as $$ begin
  insert into private.lca_release_runs(id,release_version,selection_manifest_hash,input_manifest_hash,calculation_bundle_hash,calculation_bundle_ref,profile_lock_hash,publish_plan_hash,publish_plan,artifact_set_hash,idempotency_key,request_hash,created_by)
  values(pg_temp.case_id(p_case,7),'02.00.'||lpad(p_case::text,3,'0'),repeat('d',64),repeat('d',64),repeat('a',64),(select diagnostics->'calculation_bundle' from private.lca_results where id=pg_temp.case_id(p_case,4)),repeat('d',64),repeat('d',64),'{}',repeat('d',64),'partial-release-test-'||p_case,repeat('d',64),'83400000-0000-4000-8000-000000000001');
end $$;
select lives_ok($$select pg_temp.prepare_release(1)$$,'preparing a private release plan does not claim complete LCIA');
select throws_ok($$update private.lca_release_runs set status='ready_for_approval' where id=pg_temp.case_id(1,7)$$,'23514','lcia_complete_result_required','partial result cannot pass formal full release finalization');
select lives_ok($$select pg_temp.prepare_release(3);update private.lca_release_runs set status='ready_for_approval' where id=pg_temp.case_id(3,7)$$,'registered complete result passes the added formal finalization guard');

select set_config('request.jwt.claims','{"role":"service_role"}',true);
select is(api.svc_lca_calculation_export('83400000-0000-4000-8000-000000000001',pg_temp.case_id(1,5),'parquet',false)->>'ok','true','private partial bundle v3 export status is admitted without enqueue');
select is(api.svc_lca_calculation_export('83400000-0000-4000-8000-000000000001',pg_temp.case_id(2,5),'parquet',false)->>'ok','true','all-unavailable bundle retains private inventory export');
select is((select count(*) from private.worker_jobs where job_kind='lca.calculation_export'),0::bigint,'read/status does not enqueue an export');

-- Current-lease recovery uses the actual V3 closure predicate and established
-- V2 certificate binding/insert trigger. All inputs are synthetic immutable
-- artifact metadata inside this rollback transaction; no numerical solve runs.
create function pg_temp.prepare_partial_v3(p_case integer) returns void
language plpgsql as $$
declare
  v_scope jsonb;
  v_input jsonb;
  v_input_hash text;
  v_report_hash text;
  v_resolved timestamptz:=clock_timestamp();
  v_check private.lcia_scope_closure_checks%rowtype;
begin
  perform pg_temp.insert_private_case(p_case,'partial');
  delete from private.lcia_result_packages where id=pg_temp.case_id(p_case,5);
  v_scope:=jsonb_build_object('coverageMode','subset','eligibilityPredicateVersion','partial-ready-fixture.v1',
    'processes',jsonb_build_array(jsonb_build_object('id','cccccccc-cccc-4ccc-8ccc-cccccccccccc','version','01.00.000')),
    'lciaMethods',jsonb_build_array(jsonb_build_object('id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','version','01.00.000'),jsonb_build_object('id','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','version','02.00.000')));
  v_input:=jsonb_build_object('predicateVersion','partial-ready-fixture.v1','selectionMode','closure_certificate','processes',v_scope->'processes');
  v_input_hash:=private.lcia_scope_closure_sha256(v_input);
  insert into private.worker_jobs(id,job_kind,worker_queue,subject_type,subject_id,requester_type,requested_by,status,payload_schema_version,payload_json)
    values(pg_temp.case_id(p_case,20),'lcia.scope_closure_check','solver','lcia_scope_closure_check',pg_temp.case_id(p_case,21),'operator','83400000-0000-4000-8000-000000000001','completed','lcia.scope_closure_check.request.v1','{}');
  insert into private.worker_job_artifacts(id,job_id,artifact_type,storage_bucket,storage_path,content_type,byte_size,checksum_sha256,metadata,expires_at,artifact_role,lifecycle_state)
    values(pg_temp.case_id(p_case,22),pg_temp.case_id(p_case,20),'closure_report_xlsx','partial-ready-test','report.xlsx','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',101,repeat('5',64),'{}',now()+interval '1 day','closure_report','ready'),
      (pg_temp.case_id(p_case,23),pg_temp.case_id(p_case,20),'closure_complete_machine_result','partial-ready-test','machine.json','application/vnd.tiangong.scope-closure-manifest+json',102,repeat('8',64),jsonb_build_object('closureCheckId',pg_temp.case_id(p_case,21)),now()+interval '1 day','complete_machine_result','ready'),
      (pg_temp.case_id(p_case,24),pg_temp.case_id(p_case,20),'closure_bundle','partial-ready-test','bundle.json','application/json',103,repeat('6',64),jsonb_build_object('closureCheckId',pg_temp.case_id(p_case,21),'completeMachineResultArtifactId',pg_temp.case_id(p_case,23)),now()+interval '1 day','closure_bundle','ready');
  v_report_hash:=private.lcia_scope_closure_sha256(jsonb_build_object('artifactId',pg_temp.case_id(p_case,22),'bucket','partial-ready-test','objectPath','report.xlsx','mediaType','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','byteSize',101,'checksumSha256',repeat('5',64)));
  insert into private.lca_snapshot_artifacts(id,snapshot_id,artifact_url,artifact_sha256,artifact_byte_size,artifact_format,process_count,flow_count,impact_count,a_nnz,b_nnz,c_nnz,status,snapshot_index_sha256,snapshot_build_contract_hash,effective_scope_hash,data_snapshot_token,closure_bundle_hash)
    values(pg_temp.case_id(p_case,25),pg_temp.case_id(p_case,3),'s3://partial-ready-test/snapshot.h5',repeat('7',64),100,'snapshot-hdf5:v1',1,1,2,1,1,1,'ready',repeat('9',64),repeat('a',64),repeat('3',64),'partial-ready-snapshot-'||p_case,repeat('6',64));
  insert into private.lcia_scope_closure_checks(id,worker_job_id,requested_by,request_idempotency_token,request_key,request_fingerprint,requested_scope_hash,effective_scope_hash,policy_fingerprint,data_snapshot_token,expected_validator_scanner_fingerprint,status,scan_completeness,certificate_status,certificate_hash,report_artifact_id,result_summary,finished_at,requested_scope_manifest,effective_scope_manifest,certificate_schema_version,source_fingerprint,resolution_map_hash,closure_bundle_hash,snapshot_id,snapshot_hash,report_artifact_manifest_hash,evidence_hash,closure_bundle_artifact_id,snapshot_artifact_id,snapshot_index_sha256,snapshot_build_contract_hash,complete_machine_result_artifact_id,valid_until)
    values(pg_temp.case_id(p_case,21),pg_temp.case_id(p_case,20),'83400000-0000-4000-8000-000000000001','partial-ready-'||p_case,'partial-ready-'||p_case,repeat('f',64),repeat('1',64),repeat('3',64),repeat('2',64),'partial-ready-snapshot-'||p_case,'scope-closure-validator-scanner.v1+cutoff-readiness-r7','passed','complete','valid',repeat('4',64),pg_temp.case_id(p_case,22),'{}',clock_timestamp(),'{"certificateFreshnessPolicy":"frozen-artifact-reusable-v1"}',v_scope,'lcia.scope-closure-certificate.v2','partial-ready-fixture',repeat('5',64),repeat('6',64),pg_temp.case_id(p_case,3),repeat('7',64),v_report_hash,repeat('8',64),pg_temp.case_id(p_case,24),pg_temp.case_id(p_case,25),repeat('9',64),repeat('a',64),pg_temp.case_id(p_case,23),now()+interval '1 day');
  select * into v_check from private.lcia_scope_closure_checks where id=pg_temp.case_id(p_case,21);
  update private.worker_jobs set status='running',subject_type='lcia_result_build',subject_id=pg_temp.case_id(p_case,2),lease_token='83400000-0000-4000-8000-000000000098',lease_expires_at=clock_timestamp()+interval '1 hour',payload_schema_version='lcia_result.package_build.request.v3',
    payload_json=jsonb_build_object('type','lcia_result_package_build','job_id',pg_temp.case_id(p_case,2),'build_id',pg_temp.case_id(p_case,2),'coverage_mode','subset','input_manifest',v_input,'input_manifest_hash',v_input_hash,'effective_scope',v_scope,'lcia_method_set',v_scope->'lciaMethods','eligibility_resolved_at',v_resolved,'eligible_input_count',1,'included_input_count',1,'default_impact_category','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'closure_check_id',v_check.id,'closure_certificate_hash',v_check.certificate_hash,'requested_scope_hash',v_check.requested_scope_hash,'policy_fingerprint',v_check.policy_fingerprint,'effective_scope_hash',v_check.effective_scope_hash,'data_snapshot_token',v_check.data_snapshot_token,'snapshot_id',v_check.snapshot_id,'snapshot_hash',v_check.snapshot_hash,'closure_bundle_artifact_id',v_check.closure_bundle_artifact_id,'closure_bundle_hash',v_check.closure_bundle_hash,'report_artifact_manifest_hash',v_check.report_artifact_manifest_hash,'snapshot_artifact_id',v_check.snapshot_artifact_id,'snapshot_index_sha256',v_check.snapshot_index_sha256,'snapshot_build_contract_hash',v_check.snapshot_build_contract_hash,'portalProjectionContractVersion','portal.lcia-projection.v1','portalProjectionHashContractVersion','portal.lcia-projection.int32be-frame-sha256.v1')
    where id=pg_temp.case_id(p_case,1);
  insert into private.lca_latest_all_unit_results(id,snapshot_id,job_id,result_id,query_artifact_url,query_artifact_sha256,query_artifact_byte_size,query_artifact_format,status,worker_job_id)
    values(pg_temp.case_id(p_case,6),pg_temp.case_id(p_case,3),pg_temp.case_id(p_case,2),pg_temp.case_id(p_case,4),'s3://partial-ready-test/query.json',repeat('d',64),202,'all-unit-query:v3','ready',pg_temp.case_id(p_case,1));
end $$;

create function pg_temp.partial_ready(p_case integer,p_lease uuid,p_patch jsonb default '{}',p_legacy boolean default false) returns jsonb
language plpgsql as $$
declare
  v_job private.worker_jobs%rowtype;
  v_result private.lca_results%rowtype;
  v_latest private.lca_latest_all_unit_results%rowtype;
  v_manifest jsonb;
  v_result_ref jsonb;
  v_query_ref jsonb;
begin
  select * into v_job from private.worker_jobs where id=pg_temp.case_id(p_case,1);
  select * into v_result from private.lca_results where id=pg_temp.case_id(p_case,4);
  select * into v_latest from private.lca_latest_all_unit_results where id=pg_temp.case_id(p_case,6);
  v_result_ref:=jsonb_build_object('artifactUrl',v_result.artifact_url,'artifactSha256',v_result.artifact_sha256,'artifactByteSize',v_result.artifact_byte_size,'artifactFormat',v_result.artifact_format);
  v_query_ref:=jsonb_build_object('artifactUrl',v_latest.query_artifact_url,'artifactSha256',v_latest.query_artifact_sha256,'artifactByteSize',v_latest.query_artifact_byte_size,'artifactFormat',v_latest.query_artifact_format);
  v_manifest:=jsonb_build_object('lciaAvailability',pg_temp.availability(),'calculationBundle',v_result.diagnostics->'calculation_bundle','queryArtifact',v_query_ref,'inputManifestHash',v_job.payload_json->>'input_manifest_hash','scopeClosureEvidence',jsonb_build_object(
    'closureCheckId',v_job.payload_json->>'closure_check_id','certificateHash',v_job.payload_json->>'closure_certificate_hash','effectiveScopeHash',v_job.payload_json->>'effective_scope_hash','dataSnapshotToken',v_job.payload_json->>'data_snapshot_token','snapshotId',v_job.payload_json->>'snapshot_id','snapshotHash',v_job.payload_json->>'snapshot_hash','closureBundleHash',v_job.payload_json->>'closure_bundle_hash','closureBundleArtifactId',v_job.payload_json->>'closure_bundle_artifact_id','reportArtifactManifestHash',v_job.payload_json->>'report_artifact_manifest_hash'))||p_patch;
  if p_legacy then return private.cmd_lcia_result_package_mark_ready(v_job.id,'lcia-result-'||pg_temp.case_id(p_case,2)::text,v_result.snapshot_id,v_result.id,v_latest.id,v_result_ref,v_query_ref,v_manifest,'["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]',null,repeat('c',64),'{}'); end if;
  return private.svc_lcia_result_package_partial_mark_ready_v1(v_job.id,p_lease,'lcia-result-'||pg_temp.case_id(p_case,2)::text,v_result.snapshot_id,v_result.id,v_latest.id,v_result_ref,v_query_ref,v_manifest,'["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]',null,repeat('c',64),'{}');
end $$;

select lives_ok($$select pg_temp.prepare_partial_v3(4)$$,'prepare a real certificate-bound V3 private partial fixture');
create temporary table partial_job_before as select to_jsonb(j) as body from private.worker_jobs j where id=pg_temp.case_id(4,1);
select is(pg_temp.partial_ready(4,'83400000-0000-4000-8000-000000000099')->>'code','build_worker_job_lease_invalid','stale attempt A cannot publish after claimant B owns the lease');
select is(pg_temp.partial_ready(4,'83400000-0000-4000-8000-000000000098','{}',true)->>'code','build_worker_job_explicit_lease_required','tokenless V3 entry point cannot bypass the submitted lease');
select is((select count(*) from private.lcia_result_packages where build_worker_job_id=pg_temp.case_id(4,1)),0::bigint,'rejected attempts insert no partial package');
select is((select to_jsonb(j) from private.worker_jobs j where id=pg_temp.case_id(4,1)),(select body from partial_job_before),'rejected attempts preserve the exact current job row');
create temporary table partial_ready_receipts(label text primary key,body jsonb);
insert into partial_ready_receipts values('first',pg_temp.partial_ready(4,'83400000-0000-4000-8000-000000000098'));
select is((select body->>'ok' from partial_ready_receipts where label='first'),'true','current caller B commits one bound partial package');
select is((select body->>'reused' from partial_ready_receipts where label='first'),'false','initial partial commit is not falsely labeled reuse');
select is((select default_impact_category from private.lcia_result_packages where build_worker_job_id=pg_temp.case_id(4,1)),null::text,'unavailable requested default stays absent through legacy insertion');
select is((select payload_schema_version from private.worker_jobs where id=pg_temp.case_id(4,1)),'lcia_result.package_build.request.v3','temporary V2 compatibility schema is restored');
select is((select payload_json from private.worker_jobs where id=pg_temp.case_id(4,1)),(select body->'payload_json' from partial_job_before),'original default and every payload field are restored');
insert into partial_ready_receipts values('response_loss',pg_temp.partial_ready(4,'83400000-0000-4000-8000-000000000098'));
select is((select body->>'reused' from partial_ready_receipts where label='response_loss'),'true','same caller recovers after response loss without a duplicate insert');
select is((select body->'data'->>'packageId' from partial_ready_receipts where label='response_loss'),(select body->'data'->>'packageId' from partial_ready_receipts where label='first'),'response-loss retry returns the exact committed package');
insert into partial_ready_receipts values('restart',private.svc_lcia_result_package_ready_readback_v1(pg_temp.case_id(4,1),'83400000-0000-4000-8000-000000000098'));
select is((select body->>'ok' from partial_ready_receipts where label='restart'),'true','restart reads a committed partial package without a Portal projection');
select is((select body->'data'->'lciaAvailability' from partial_ready_receipts where label='restart'),pg_temp.availability(),'restart returns the exact frozen availability');
select ok(not (select body->'data' ? 'projection' from partial_ready_receipts where label='restart'),'partial receipt never invents a projection');
update private.worker_jobs set lease_token='83400000-0000-4000-8000-000000000097' where id=pg_temp.case_id(4,1);
select is(private.svc_lcia_result_package_ready_readback_v1(pg_temp.case_id(4,1),'83400000-0000-4000-8000-000000000098')->>'code','projection_lease_invalid','old claimant B cannot read back under reclaimed lease C');
select is(private.svc_lcia_result_package_ready_readback_v1(pg_temp.case_id(4,1),'83400000-0000-4000-8000-000000000097')->'data'->>'packageId',(select body->'data'->>'packageId' from partial_ready_receipts where label='first'),'current claimant C recovers the immutable package');
select is(pg_temp.partial_ready(4,'83400000-0000-4000-8000-000000000097')->>'reused','true','reclaimed caller repeats the exact ready request without a new package');
update private.worker_jobs set payload_json=payload_json||'{"additional_bound_request_field":true}' where id=pg_temp.case_id(4,1);
select is(private.svc_lcia_result_package_ready_readback_v1(pg_temp.case_id(4,1),'83400000-0000-4000-8000-000000000097')->>'code','projection_package_binding_invalid','even extra original-body drift invalidates committed partial readback');
update private.worker_jobs set payload_json=(select body->'payload_json' from partial_job_before) where id=pg_temp.case_id(4,1);
select is(pg_temp.partial_ready(4,'83400000-0000-4000-8000-000000000097','{"privatePartialReadyRequestHash":"forged"}')->>'code','projection_package_binding_invalid','caller cannot supply a forged reserved binding hash');
select is(pg_temp.partial_ready(4,'83400000-0000-4000-8000-000000000097','{"arbitrary_extra_manifest_field":true}')->>'code','projection_package_binding_invalid','retry cannot weaken exact manifest equality with extra caller fields');
update private.lca_latest_all_unit_results set query_artifact_sha256=repeat('f',64) where id=pg_temp.case_id(4,6);
select is(private.svc_lcia_result_package_ready_readback_v1(pg_temp.case_id(4,1),'83400000-0000-4000-8000-000000000097')->>'code','projection_package_binding_invalid','current query artifact drift cannot recover stale partial values');
update private.lca_latest_all_unit_results set query_artifact_sha256=repeat('d',64) where id=pg_temp.case_id(4,6);
select is((select count(*) from private.lcia_result_packages where build_worker_job_id=pg_temp.case_id(4,1)),1::bigint,'all retries and reclaims retain one immutable package');

select lives_ok($$select pg_temp.prepare_partial_v3(5)$$,'prepare separate V3 fixture for late postcondition failure');
create temporary table partial_rollback_before as select to_jsonb(j) as body from private.worker_jobs j where id=pg_temp.case_id(5,1);
create function pg_temp.partial_late_drift() returns trigger language plpgsql as $$ begin new.default_impact_category:='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';return new;end $$;
create trigger z_partial_late_drift before insert on private.lcia_result_packages for each row when(new.build_worker_job_id=pg_temp.case_id(5,1)) execute function pg_temp.partial_late_drift();
select is(pg_temp.partial_ready(5,'83400000-0000-4000-8000-000000000098')->>'code','lcia_private_package_validation_failed','late drift fails the exact partial postcondition');
select is((select count(*) from private.lcia_result_packages where build_worker_job_id=pg_temp.case_id(5,1)),0::bigint,'late failure rolls back the partial package insert');
select is((select to_jsonb(j) from private.worker_jobs j where id=pg_temp.case_id(5,1)),(select body from partial_rollback_before),'late failure restores the entire job row including original schema and payload');
drop trigger z_partial_late_drift on private.lcia_result_packages;

-- Complete legacy default normalization is distinct from deliberate partial
-- NULL. Use the real certificate chain and reject even attempted payload UPDATEs.
create function pg_temp.prepare_complete_v2(p_case integer,p_payload_default text) returns void language plpgsql as $$ begin
  perform pg_temp.prepare_partial_v3(p_case);
  update private.lca_network_snapshots set process_filter=jsonb_set(process_filter,'{lcia_availability}',pg_temp.availability('complete')) where id=pg_temp.case_id(p_case,3);
  update private.lca_results set diagnostics=jsonb_set(jsonb_set(diagnostics,'{lcia_availability}',pg_temp.availability('complete')),'{calculation_bundle,schemaVersion}','"tiangong.calculation-bundle.v2"') where id=pg_temp.case_id(p_case,4);
  update private.worker_jobs set payload_schema_version='lcia_result.package_build.request.v2',payload_json=jsonb_set(payload_json,'{default_impact_category}',coalesce(to_jsonb(p_payload_default),'null'::jsonb)) where id=pg_temp.case_id(p_case,1);
end $$;
select lives_ok($$select pg_temp.prepare_complete_v2(10,'  bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb  ')$$,'prepare complete V2 with a whitespace-padded available payload default');
select lives_ok($$select pg_temp.prepare_complete_v2(11,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$$,'prepare complete V2 empty-caller fallback control');
select lives_ok($$select pg_temp.prepare_complete_v2(12,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$$,'prepare complete V2 spaces-caller fallback control');
select lives_ok($$select pg_temp.prepare_complete_v2(13,'   ')$$,'prepare complete V2 whitespace-only payload default');
select lives_ok($$select pg_temp.prepare_complete_v2(14,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$$,'prepare complete V2 explicit caller override');
create temporary table complete_v2_request_before as select id,jsonb_build_object('payload',payload_json,'schema',payload_schema_version,'lease',lease_token,'expires',lease_expires_at) body from private.worker_jobs where id in (pg_temp.case_id(10,1),pg_temp.case_id(11,1),pg_temp.case_id(12,1),pg_temp.case_id(13,1),pg_temp.case_id(14,1));
create function pg_temp.reject_complete_v2_payload_update() returns trigger language plpgsql as $$ begin
  if new.id in (pg_temp.case_id(10,1),pg_temp.case_id(11,1),pg_temp.case_id(12,1),pg_temp.case_id(13,1),pg_temp.case_id(14,1)) then raise exception 'complete V2 callback attempted a payload UPDATE';end if;
  return new;
end $$;
create trigger aaa_complete_v2_no_payload_update before update of payload_json on private.worker_jobs for each row execute function pg_temp.reject_complete_v2_payload_update();
create function pg_temp.complete_v2_ready(p_case integer,p_caller_default text) returns jsonb language sql as $$
  select private.cmd_lcia_result_package_mark_ready(j.id,'complete-v2-default-'||p_case,r.snapshot_id,r.id,a.id,
    jsonb_build_object('artifactUrl',r.artifact_url,'artifactSha256',r.artifact_sha256,'artifactByteSize',r.artifact_byte_size,'artifactFormat',r.artifact_format),
    jsonb_build_object('artifactUrl',a.query_artifact_url,'artifactSha256',a.query_artifact_sha256,'artifactByteSize',a.query_artifact_byte_size,'artifactFormat',a.query_artifact_format),
    jsonb_build_object('lciaAvailability',r.diagnostics->'lcia_availability','calculationBundle',r.diagnostics->'calculation_bundle'),
    '["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]',p_caller_default,r.artifact_sha256,'{}')
  from private.worker_jobs j join private.lca_results r on r.id=pg_temp.case_id(p_case,4)
    join private.lca_latest_all_unit_results a on a.id=pg_temp.case_id(p_case,6) where j.id=pg_temp.case_id(p_case,1)
$$;
select is(pg_temp.complete_v2_ready(10,null)->>'ok','true','complete V2 NULL caller default preserves available normalized payload fallback');
select is(pg_temp.complete_v2_ready(11,'')->>'ok','true','complete V2 empty caller default preserves payload fallback');
select is(pg_temp.complete_v2_ready(12,'   ')->>'ok','true','complete V2 spaces caller default preserves payload fallback');
select is(pg_temp.complete_v2_ready(13,null)->>'ok','true','complete V2 whitespace-only payload remains absent without inventing a first category');
select is(pg_temp.complete_v2_ready(14,'  aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa  ')->>'ok','true','complete V2 explicit caller default is normalized and overrides payload fallback');
select is((select count(*) from private.lcia_result_packages where build_worker_job_id in (pg_temp.case_id(10,1),pg_temp.case_id(11,1),pg_temp.case_id(12,1)) and default_impact_category='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),3::bigint,'all three complete fallback packages retain the exact normalized payload method');
select is((select default_impact_category from private.lcia_result_packages where build_worker_job_id=pg_temp.case_id(13,1)),null::text,'whitespace-only complete fallback stays NULL');
select is((select default_impact_category from private.lcia_result_packages where build_worker_job_id=pg_temp.case_id(14,1)),'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','explicit complete caller default wins after the preserved trim rule');
select ok(not exists(select 1 from complete_v2_request_before b join private.worker_jobs j using(id) where jsonb_build_object('payload',j.payload_json,'schema',j.payload_schema_version,'lease',j.lease_token,'expires',j.lease_expires_at) is distinct from b.body),'successful complete defaults preserve every payload/schema/lease field with no payload UPDATE');
drop trigger aaa_complete_v2_no_payload_update on private.worker_jobs;

select * from finish();
rollback;
