-- Synthetic scale fixture; caller must wrap it in a rollback-only transaction.
set local session_replication_role = replica;
insert into private.users(id) values
 ('76600000-0000-4000-8000-000000000001'),
 ('76600000-0000-4000-8000-000000000002'),
 ('76600000-0000-4000-8000-000000000003');
insert into private.roles(user_id,team_id,role) values
 ('76600000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','review-member');
insert into public.sources(id,version,state_code,user_id,json,json_ordered,reviews)
select md5('source-766-'||g)::uuid,'00.00.001',
 case when g<=161 then 20 when g<=3048 then 0 else 100 end,
 '76600000-0000-4000-8000-000000000002',
 jsonb_build_object('sourceDataSet',jsonb_build_object('sourceInformation',jsonb_build_object('dataSetInformation',jsonb_build_object('sourceCitation',case when g=14420 then '766-hit' else '766-citation-'||g end)),'administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:dataSetVersion','00.00.001')))),
 jsonb_build_object('sourceDataSet',jsonb_build_object('sourceInformation',jsonb_build_object('dataSetInformation',jsonb_build_object('sourceCitation',case when g=14420 then '766-hit' else '766-citation-'||g end)),'administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:dataSetVersion','00.00.001'))))::json,
 '[]'::jsonb
from generate_series(1,14420)g;
insert into private.reviews(id,data_id,data_version,state_code,reviewer_id,json,review_kind,target_table,submitted_revision_checksum,target_owner_id)
select md5('review-766-'||g)::uuid,md5('review-data-766-'||g)::uuid,'00.00.001',1,
 '["76600000-0000-4000-8000-000000000003"]'::jsonb,
 jsonb_build_object('data',jsonb_build_object('id',md5('review-data-766-'||g)::uuid,'version','00.00.001','table','processes'),'user',jsonb_build_object('id','76600000-0000-4000-8000-000000000002')),
 'root','processes',md5('review-766-'||g)||md5('review-766-'||g),'76600000-0000-4000-8000-000000000002'
from generate_series(1,2789)g;
set local session_replication_role = origin;
analyze public.sources;
analyze private.reviews;
analyze private.roles;
