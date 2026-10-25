-- Database #869: exact Flow CAS, lexical Process and scope regression through real writers.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions,public,auth;
select extensions.no_plan();

create or replace function pg_temp.portal_versions_localized(p_text text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('@xml:lang', 'en', '#text', p_text)
  )
$$;

create or replace function pg_temp.portal_versions_publication(
  p_version text,
  p_license text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'common:dataSetVersion', p_version,
    'common:licenseType', p_license,
    'common:referenceToOwnershipOfDataSet', pg_catalog.jsonb_build_object(
      '@type', 'contact data set',
      '@refObjectId', '52900000-0000-4000-8000-000000000900',
      '@version', '01.00.000',
      '@uri', 's3://portal-private/provider.json',
      'common:shortDescription', pg_temp.portal_versions_localized('Portal Provider')
    )
  )
$$;

create or replace function pg_temp.portal_versions_process_payload(
  p_name text,
  p_version text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'processDataSet', pg_catalog.jsonb_build_object(
      'processInformation', pg_catalog.jsonb_build_object(
        'dataSetInformation', pg_catalog.jsonb_build_object(
          'name', pg_catalog.jsonb_build_object(
            'baseName', pg_temp.portal_versions_localized(p_name)
          ),
          'common:generalComment', pg_temp.portal_versions_localized(p_name || ' summary'),
          'classificationInformation', pg_catalog.jsonb_build_object(
            'common:classification', pg_catalog.jsonb_build_array(
              pg_catalog.jsonb_build_object(
                'common:class', pg_catalog.jsonb_build_object(
                  '@level', '0', '@classId', 'PORTAL-HYBRID', '#text', 'Hybrid fixture'
                )
              )
            )
          )
        ),
        'time', pg_catalog.jsonb_build_object('common:referenceYear', '2024'),
        'geography', pg_catalog.jsonb_build_object(
          'locationOfOperationSupplyOrProduction', pg_catalog.jsonb_build_object(
            '@location', 'CN',
            'descriptionOfRestrictions', pg_temp.portal_versions_localized('China')
          )
        ),
        'technology', pg_catalog.jsonb_build_object(
          'technologyDescriptionAndIncludedProcesses',
          pg_temp.portal_versions_localized('Hybrid fixture technology')
        )
      ),
      'modellingAndValidation', pg_catalog.jsonb_build_object(
        'LCIMethodAndAllocation', pg_catalog.jsonb_build_object(
          'typeOfDataSet', 'Unit process, single operation'
        )
      ),
      'administrativeInformation', pg_catalog.jsonb_build_object(
        'publicationAndOwnership', pg_temp.portal_versions_publication(
          p_version, 'Free of charge for all users and uses'
        )
      ),
      'privateLocator', 's3://portal-private/process/' || p_name
    )
  )
$$;

create or replace function pg_temp.portal_versions_flow_payload(
  p_name text,
  p_version text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'flowDataSet', pg_catalog.jsonb_build_object(
      'flowInformation', pg_catalog.jsonb_build_object(
        'dataSetInformation', pg_catalog.jsonb_build_object(
          'name', pg_catalog.jsonb_build_object(
            'baseName', pg_temp.portal_versions_localized(p_name)
          ),
          'common:generalComment', pg_temp.portal_versions_localized(p_name || ' summary'),
          'classificationInformation', pg_catalog.jsonb_build_object(
            'common:classification', pg_catalog.jsonb_build_array(
              pg_catalog.jsonb_build_object(
                'common:class', pg_catalog.jsonb_build_object(
                  '@level', '0', '@classId', 'PORTAL-HYBRID', '#text', 'Hybrid fixture'
                )
              )
            )
          ),
          'CASNumber', '50-00-0'
        ),
        'geography', pg_catalog.jsonb_build_object(
          'locationOfSupply', pg_catalog.jsonb_build_object(
            '@location', 'CN',
            'descriptionOfRestrictions', pg_temp.portal_versions_localized('China')
          )
        )
      ),
      'modellingAndValidation', pg_catalog.jsonb_build_object(
        'LCIMethod', pg_catalog.jsonb_build_object('typeOfDataSet', 'Product flow')
      ),
      'administrativeInformation', pg_catalog.jsonb_build_object(
        'publicationAndOwnership', pg_temp.portal_versions_publication(
          p_version, 'Free of charge for all users and uses'
        )
      ),
      'objectLocator', 's3://portal-private/flow/' || p_name
    )
  )
$$;


create or replace function util.invoke_edge_function(name text,body jsonb,timeout_milliseconds integer default 300000)
returns void language plpgsql security definer set search_path='' as $$begin return; end$$;
-- BEGIN CAS869 REAL WRITER FIXTURE
create or replace function pg_temp.portal_cas869_payload(p_name text,p_version text,p_cas jsonb)
returns jsonb language sql immutable set search_path='' as $$
 select jsonb_set(pg_temp.portal_versions_flow_payload(p_name,p_version),
  '{flowDataSet,flowInformation,dataSetInformation,CASNumber}',p_cas)
$$;
insert into public.flows(id,version,state_code,json) values
 ('86900000-0000-4000-8000-000000000101','01.00.000',0,pg_temp.portal_cas869_payload('Aldehyde historical869','01.00.000','"50-00-0"')),
 ('86900000-0000-4000-8000-000000000101','02.00.000',200,pg_temp.portal_cas869_payload('Aldehyde current869','02.00.000','"50-00-0"')),
 ('86900000-0000-4000-8000-000000000102','01.00.000',100,pg_temp.portal_cas869_payload('Another common869','01.00.000','"50-00-0"')),
 ('86900000-0000-4000-8000-000000000103','01.00.000',20,pg_temp.portal_cas869_payload('Rare alcohol869','01.00.000','"64-17-5"')),
 ('86900000-0000-4000-8000-000000000104','01.00.000',100,pg_temp.portal_cas869_payload('Text only 50-00-0 falsepositive869','01.00.000','"67-56-1"')),
 ('86900000-0000-4000-8000-000000000105','01.00.000',100,pg_temp.portal_cas869_payload('CAS superstring869','01.00.000','"150-00-0"')),
 ('86900000-0000-4000-8000-000000000106','01.00.000',100,pg_temp.portal_cas869_payload('Invalid CAS869','01.00.000','"invalid869"')),
 ('86900000-0000-4000-8000-000000000107','01.00.000',100,pg_temp.portal_cas869_payload('Numeric CAS869','01.00.000','50000')),
 ('86900000-0000-4000-8000-000000000108','01.00.000',100,pg_temp.portal_cas869_payload('Object CAS869','01.00.000','{"#text":"50-00-0"}')),
 ('86900000-0000-4000-8000-000000000109','01.00.000',100,
  jsonb_set(pg_temp.portal_versions_flow_payload('Namespace CAS869','01.00.000')
   #- '{flowDataSet,flowInformation,dataSetInformation,CASNumber}',
   '{flowDataSet,flowInformation,dataSetInformation,common:CASNumber}','" 50-00-0 "')),
 ('86900000-0000-4000-8000-000000000110','01.00.000',100,pg_temp.portal_cas869_payload('Hidden exact869','01.00.000','"50-00-0"'));
insert into public.processes(id,version,state_code,json) values
 ('86900000-0000-4000-8000-000000000111','01.00.000',0,
  pg_temp.portal_versions_process_payload('Process text 50-00-0 lexical869','01.00.000'));
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand)
select 'flow',id,version,true,
 case when right(id::text,3)='101' and version='01.00.000' then 'tiangong_lca'
      when right(id::text,3)='103' then 'uslci'
      when right(id::text,3)='109' then 'tiangong_lca' else 'bafu' end
from public.flows where id::text like '86900000-%' and right(id::text,3)<>'110';
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand)
values('process','86900000-0000-4000-8000-000000000111','01.00.000',true,'worldsteel');
set constraints all immediate;
-- END CAS869 REAL WRITER FIXTURE

update private.portal_display_rollout set mode='display';
create function pg_temp.cas869_count(p_page jsonb,p_group text,p_value text)
returns bigint language sql immutable set search_path='' as $$
 select coalesce((select (v->>'count')::bigint from jsonb_array_elements(p_page->'groups') g
 cross join lateral jsonb_array_elements(g->'values') v
 where g->>'id'=p_group and v->>'value'=p_value),0)
$$;
create temp table cas869_responses(label text primary key,page jsonb);
grant execute on function pg_temp.cas869_count(jsonb,text,text) to anon;
grant select,insert on cas869_responses to anon;
set local role anon;
insert into cas869_responses values
 ('common',api.portal_facets_v4(array['tiangong_lca','bafu','uslci','worldsteel'],'all','50-00-0')),
 ('rare',api.portal_facets_v4(array['tiangong_lca','bafu','uslci','worldsteel'],'flow','64-17-5')),
 ('absent',api.portal_facets_v4(array['tiangong_lca','bafu','uslci','worldsteel'],'all','75-07-0')),
 ('historical',api.portal_facets_v4(array['tiangong_lca'],'flow',' 50-00-0 ')),
 ('brand',api.portal_facets_v4(array['tiangong_lca','bafu'],'all','50-00-0','{"brand":"bafu","geography":"CN"}')),
 ('outscope',api.portal_facets_v4(array['tiangong_lca'],'flow','50-00-0','{"brand":"bafu"}')),
 ('year',api.portal_facets_v4(array['tiangong_lca','bafu','uslci','worldsteel'],'all','50-00-0','{"referenceYearFrom":2024}')),
 ('superstring',api.portal_facets_v4(array['bafu'],'flow','150-00-0')),
 ('invalid',api.portal_facets_v4(array['bafu'],'flow','invalid869')),
 ('navigation',api.portal_navigation_v2(array['tiangong_lca','bafu','uslci','worldsteel'],'all','50-00-0','{}','geography'));
select is(pg_temp.cas869_count(page,'kind','flow'),4::bigint,'exact CAS includes all historical/current matches with unrelated names and namespace CAS') from cas869_responses where label='common';
select is(pg_temp.cas869_count(page,'kind','process'),1::bigint,'CAS-shaped Process remains lexical') from cas869_responses where label='common';
select is(pg_temp.cas869_count(page,'brand','bafu'),2::bigint,'Flow lexical false positive and CAS superstring cannot inflate brand counts') from cas869_responses where label='common';
select is(pg_temp.cas869_count(page,'kind','flow'),1::bigint,'rare CAS matches a name containing no CAS') from cas869_responses where label='rare';
select is(pg_temp.cas869_count(page,'kind','flow'),0::bigint,'absent valid CAS returns complete zero Flow count') from cas869_responses where label='absent';
select is(pg_temp.cas869_count(page,'kind','process'),0::bigint,'absent valid CAS returns complete zero Process count') from cas869_responses where label='absent';
select is(pg_temp.cas869_count(page,'kind','flow'),2::bigint,'single-brand query includes historical version and trims query') from cas869_responses where label='historical';
select is(pg_temp.cas869_count(page,'kind','flow'),2::bigint,'combined geography and brand filters preserve exact current versions') from cas869_responses where label='brand';
select is(pg_temp.cas869_count(page,'kind','flow'),0::bigint,'brand filter cannot widen deployment scope') from cas869_responses where label='outscope';
select is(pg_temp.cas869_count(page,'kind','flow'),0::bigint,'year filter excludes nullable Flow years') from cas869_responses where label='year';
select is(pg_temp.cas869_count(page,'kind','process'),1::bigint,'year filter retains lexical Process match') from cas869_responses where label='year';
select is(pg_temp.cas869_count(page,'kind','flow'),1::bigint,'superstring is independently searchable only by its exact CAS') from cas869_responses where label='superstring';
select is(pg_temp.cas869_count(page,'kind','flow'),0::bigint,'invalid source CAS does not leak into lexical document') from cas869_responses where label='invalid';
select is(page->'totals','{"process":1,"flow":4}'::jsonb,'Navigation exact-version totals agree with complete Facets counts') from cas869_responses where label='navigation';
select throws_ok($q$select * from private.display_catalog_search_rows_v1$q$,'42501',null,'anonymous direct projection access remains closed');
select throws_ok($q$select * from private.display_navigation_matched_versions_v1('flow','50-00-0','{}')$q$,'42501',null,'anonymous helper access remains closed');
reset role;
select is((select count(*) from private.display_catalog_search_rows_v1 where id in
 ('86900000-0000-4000-8000-000000000106','86900000-0000-4000-8000-000000000107','86900000-0000-4000-8000-000000000108')
 and card->'casNumber'='null'::jsonb),3::bigint,'real writers normalize invalid, numeric and object CAS to null');
select is((select count(*) from private.display_navigation_versions_v1 where id in
 ('86900000-0000-4000-8000-000000000106','86900000-0000-4000-8000-000000000107','86900000-0000-4000-8000-000000000108')
 and cas_number is null),3::bigint,'invalid, numeric and object CAS leave no native exact-CAS fact');
-- Stored lexical drift must not become an exact-CAS eligibility condition.
update private.display_catalog_search_rows_v1
set card=jsonb_set(card,'{document}','"document without registry digits869"'),
 document='document without registry digits869'
where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000103';
set local role anon;
select is(pg_temp.cas869_count(api.portal_facets_v4(array['uslci'],'flow','64-17-5'),'kind','flow'),1::bigint,'exact CAS survives a lexical document containing no CAS');
reset role;
create temp table cas869_old_navigation_facts as
 select to_jsonb(n)-'cas_number' facts from private.display_navigation_versions_v1 n
 where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000101' and version='01.00.000';
-- A real source writer changes CAS without changing the name.
update public.flows set json=pg_temp.portal_cas869_payload('Aldehyde historical869','01.00.000','"64-17-5"')
where id='86900000-0000-4000-8000-000000000101' and version='01.00.000';
select is((select cas_number from private.display_navigation_versions_v1
 where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000101' and version='01.00.000'),
 '64-17-5','CAS-only source update synchronously replaces native CAS');
select is((select to_jsonb(n)-'cas_number' from private.display_navigation_versions_v1 n
 where dataset_kind='flow' and id='86900000-0000-4000-8000-000000000101' and version='01.00.000'),
 (select facts from cas869_old_navigation_facts),'CAS-only source update preserves every old navigation fact');
set local role anon;
select is(pg_temp.cas869_count(api.portal_facets_v4(array['tiangong_lca'],'flow','50-00-0'),'kind','flow'),1::bigint,'source CAS update removes only the changed historical exact match');
select is(pg_temp.cas869_count(api.portal_facets_v4(array['tiangong_lca'],'flow','64-17-5'),'kind','flow'),1::bigint,'source CAS update adds the new exact match immediately');
reset role;
update private.dataset_display_settings set is_visible=false where dataset_kind='flow'
 and dataset_id='86900000-0000-4000-8000-000000000101' and dataset_version='02.00.000';
set local role anon;
select is(pg_temp.cas869_count(api.portal_facets_v4(array['bafu'],'flow','50-00-0'),'kind','flow'),1::bigint,'exact-version withdrawal removes only the hidden current match');
select is(api.portal_navigation_v2(array['bafu'],'flow','50-00-0','{}','geography')->'totals','{"process":0,"flow":1}'::jsonb,'Navigation observes exact-CAS withdrawal immediately');
reset role;
select * from finish();
rollback;
