#!/usr/bin/env node

/**
 * Current private SQL exact-shape proof for Issues #316 and #794.
 *
 * The runner hard-fails outside the loopback Supabase stack, reads the same
 * machine-readable fixture posted to database-engine#316 and Worker#177,
 * creates two exact disposable database contexts, exercises real private SQL
 * service-role transport, compares status with independent stored state, races the final
 * batch against seal, and removes only its fixed fixture namespace.
 */

import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { spawn, spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '../..');
const FIXTURE_PATH = path.join(
  HERE,
  'fixtures/20260730_scope_closure_staged_write_set_v2_contract.json',
);

const OWNER_ID = '31600000-0000-4000-8000-000000000001';
const CONCURRENT = Object.freeze({
  closureCheckId: '11111111-1111-4111-8111-111111111112',
  workerJobId: '22222222-2222-4222-8222-222222222223',
  workerLeaseToken: '33333333-3333-4333-8333-333333333334',
  requestId: '44444444-4444-4444-8444-444444444445',
});
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_RE = /^[0-9a-f]{64}$/;

class ContractError extends Error {
  constructor(code) {
    super(code);
    this.name = 'ContractError';
    this.code = code;
  }
}

function fail(code) {
  throw new ContractError(code);
}

let assertionCount = 0;
function assertContract(condition, code) {
  if (!condition) fail(code);
  assertionCount += 1;
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalize(value));
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function exactKeys(value, expected, code) {
  assertContract(isPlainObject(value), code);
  assertContract(
    canonicalJson(Object.keys(value).sort())
      === canonicalJson([...expected].sort()),
    code,
  );
}

function parseSupabaseEnvironment() {
  const result = spawnSync('supabase', ['status', '-o', 'env'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  assertContract(result.status === 0, 'SUPABASE_STATUS_FAILED');
  const values = {};
  for (const line of result.stdout.split(/\r?\n/)) {
    const match = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (!match) continue;
    let value = match[2];
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.slice(1, -1);
    }
    values[match[1]] = value;
  }
  for (const name of ['API_URL', 'DB_URL', 'SERVICE_ROLE_KEY']) {
    assertContract(typeof values[name] === 'string' && values[name], `ENV_${name}`);
  }
  const api = new URL(values.API_URL);
  const database = new URL(values.DB_URL);
  assertContract(
    ['127.0.0.1', 'localhost', '::1'].includes(api.hostname),
    'API_NOT_LOOPBACK',
  );
  assertContract(
    ['127.0.0.1', 'localhost', '::1'].includes(database.hostname),
    'DATABASE_NOT_LOOPBACK',
  );
  return {
    apiUrl: values.API_URL.replace(/\/$/, ''),
    databaseUrl: values.DB_URL,
    serviceRoleKey: values.SERVICE_ROLE_KEY,
  };
}

function runSql(databaseUrl, sql) {
  const result = spawnSync(
    'psql',
    [databaseUrl, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    {
      input: sql,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    },
  );
  assertContract(result.status === 0, 'SQL_COMMAND_FAILED');
  return result.stdout.trim();
}

const SQL_ARGUMENT_TYPES = Object.freeze({
  p_closure_check_id: 'uuid', p_worker_job_id: 'uuid', p_worker_lease_token: 'uuid',
  p_request_id: 'uuid', p_write_set_id: 'uuid', p_write_token: 'uuid',
  p_batch_id: 'uuid', p_reused_from_check_id: 'uuid', p_contract_version: 'text',
  p_expected_descriptor_count: 'integer', p_descriptor_set_sha256: 'text',
  p_required_primary_roles: 'jsonb', p_items: 'jsonb', p_staging_seconds: 'integer',
});

async function rpc(environment, name, body) {
  assertContract(/^svc_lcia_scope_closure_artifact_write_set_(create|register_batch|status|seal|finalize|fail)_v2$/.test(name), 'SQL_FUNCTION_ALLOWLIST');
  const args = Object.entries(body).map(([key, value]) => {
    const type = SQL_ARGUMENT_TYPES[key];
    assertContract(Boolean(type), 'SQL_ARGUMENT_ALLOWLIST');
    const text = type === 'jsonb' ? JSON.stringify(value) : String(value);
    return `${key} => ${value === null ? 'null' : "'" + text.replaceAll("'", "''") + "'"}::${type}`;
  }).join(', ');
  const sql = `with service_context as (
    select set_config('request.jwt.claim.role', 'service_role', true)
  ) select private.${name}(${args})::text from service_context;`;
  const startedAt = performance.now();
  // Separate asynchronous sessions preserve a genuine concurrent register/seal race.
  const output = await new Promise((resolve, reject) => {
    const child = spawn('psql', [environment.databaseUrl, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.resume(); // Raw transport errors can include private target details.
    child.on('error', () => reject(new ContractError('SQL_TRANSPORT_FAILED')));
    child.on('close', (code) => code === 0 ? resolve(stdout.trim()) : reject(new ContractError('SQL_TRANSPORT_FAILED')));
    child.stdin.end(sql);
  });
  let value;
  try { value = JSON.parse(output); } catch { fail('SQL_RESPONSE_NOT_JSON'); }
  return { value, elapsedMs: performance.now() - startedAt };
}

async function verifyPostgrestIsolation(environment) {
  for (const profile of ['public', 'api', 'private']) {
    const response = await fetch(`${environment.apiUrl}/rest/v1/rpc/svc_lcia_scope_closure_artifact_write_set_status_v2`, {
      method: 'POST',
      headers: { apikey: environment.serviceRoleKey, authorization: `Bearer ${environment.serviceRoleKey}`, 'content-type': 'application/json', 'accept-profile': profile, 'content-profile': profile },
      body: '{}',
    });
    const value = await response.json();
    assertContract(response.status === (profile === 'private' ? 406 : 404)
      && value.code === (profile === 'private' ? 'PGRST106' : 'PGRST202'), 'POSTGREST_HELPER_ISOLATION');
  }
}

function setupSql(exact) {
  return `
begin;
do $setup$
begin
  if exists (
    select 1 from auth.users where id = '${OWNER_ID}'::uuid
    union all
    select 1 from private.worker_jobs
    where id in (
      '${exact.workerJobId}'::uuid,
      '${CONCURRENT.workerJobId}'::uuid
    )
    union all
    select 1 from private.lcia_scope_closure_checks
    where id in (
      '${exact.closureCheckId}'::uuid,
      '${CONCURRENT.closureCheckId}'::uuid
    )
  ) then
    raise exception 'issue_316_rest_fixture_not_clean';
  end if;
end
$setup$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  '${OWNER_ID}',
  'authenticated',
  'authenticated',
  'issue-316-rest-contract@example.com',
  'x',
  now(),
  '{}',
  '{}',
  now(),
  now(),
  false,
  false
);
insert into private.users (id, raw_user_meta_data, contact)
values ('${OWNER_ID}', '{}', null);

insert into private.worker_jobs (
  id, job_kind, worker_runtime, worker_queue, requester_type, requested_by,
  visibility, payload_schema_version, payload_json, status, leased_by,
  lease_token, lease_expires_at, heartbeat_at
) values
  (
    '${exact.workerJobId}',
    'lcia.scope_closure_check',
    'calculator',
    'solver',
    'operator',
    '${OWNER_ID}',
    'operator',
    'lcia.scope_closure_check.request.v1',
    '{}',
    'running',
    'issue-316-rest-exact',
    '${exact.workerLeaseToken}',
    now() + interval '2 hours',
    now()
  ),
  (
    '${CONCURRENT.workerJobId}',
    'lcia.scope_closure_check',
    'calculator',
    'solver',
    'operator',
    '${OWNER_ID}',
    'operator',
    'lcia.scope_closure_check.request.v1',
    '{}',
    'running',
    'issue-316-rest-concurrent',
    '${CONCURRENT.workerLeaseToken}',
    now() + interval '2 hours',
    now()
  );

insert into private.lcia_scope_closure_checks (
  id, worker_job_id, requested_by, request_idempotency_token, request_key,
  request_fingerprint, requested_scope_hash, policy_fingerprint,
  data_snapshot_token, expected_validator_scanner_fingerprint, status,
  certificate_status
) values
  (
    '${exact.closureCheckId}',
    '${exact.workerJobId}',
    '${OWNER_ID}',
    'issue-316-rest-exact-token',
    'issue-316-rest-exact-key',
    repeat('1', 64),
    repeat('2', 64),
    repeat('3', 64),
    'issue-316-rest-snapshot',
    'scope-closure-validator-scanner.v1',
    'running',
    'pending'
  ),
  (
    '${CONCURRENT.closureCheckId}',
    '${CONCURRENT.workerJobId}',
    '${OWNER_ID}',
    'issue-316-rest-concurrent-token',
    'issue-316-rest-concurrent-key',
    repeat('4', 64),
    repeat('2', 64),
    repeat('3', 64),
    'issue-316-rest-snapshot',
    'scope-closure-validator-scanner.v1',
    'running',
    'pending'
  );
commit;
`;
}

function cleanupSql(exact) {
  return `
set session_replication_role = replica;
update private.lcia_scope_closure_checks
set report_artifact_id = null,
    complete_machine_result_artifact_id = null,
    closure_bundle_artifact_id = null,
    reused_from_check_id = null
where id in (
  '${exact.closureCheckId}'::uuid,
  '${CONCURRENT.closureCheckId}'::uuid
);
delete from private.worker_job_artifacts
where job_id in (
  '${exact.workerJobId}'::uuid,
  '${CONCURRENT.workerJobId}'::uuid
);
delete from private.lcia_scope_closure_artifact_write_set_batches batch
using private.lcia_scope_closure_artifact_write_sets write_set
where batch.write_set_id = write_set.id
  and write_set.closure_check_id in (
    '${exact.closureCheckId}'::uuid,
    '${CONCURRENT.closureCheckId}'::uuid
  );
delete from private.lcia_scope_closure_artifact_write_set_items item
using private.lcia_scope_closure_artifact_write_sets write_set
where item.write_set_id = write_set.id
  and write_set.closure_check_id in (
    '${exact.closureCheckId}'::uuid,
    '${CONCURRENT.closureCheckId}'::uuid
  );
delete from private.lcia_scope_closure_artifact_write_sets
where closure_check_id in (
  '${exact.closureCheckId}'::uuid,
  '${CONCURRENT.closureCheckId}'::uuid
);
delete from private.lcia_scope_closure_checks
where id in (
  '${exact.closureCheckId}'::uuid,
  '${CONCURRENT.closureCheckId}'::uuid
);
delete from private.worker_jobs
where id in (
  '${exact.workerJobId}'::uuid,
  '${CONCURRENT.workerJobId}'::uuid
);
delete from private.users where id = '${OWNER_ID}'::uuid;
delete from auth.users where id = '${OWNER_ID}'::uuid;
set session_replication_role = origin;
`;
}

function storedStatusSql(writeSetId) {
  // Read rows directly rather than comparing the same status function to itself.
  return `select jsonb_build_object(
    'writeSetId', w.id, 'closureCheckId', w.closure_check_id,
    'workerJobId', w.worker_job_id, 'requestId', w.request_id,
    'status', w.status, 'descriptorSetSha256', w.descriptor_set_sha256,
    'expectedDescriptorCount', w.expected_descriptor_count,
    'registeredDescriptorCount', (select count(*) from private.lcia_scope_closure_artifact_write_set_items i where i.write_set_id = w.id),
    'registeredBatchCount', (select count(*) from private.lcia_scope_closure_artifact_write_set_batches b where b.write_set_id = w.id),
    'artifactMap', (select jsonb_object_agg(i.client_key, i.id) from private.lcia_scope_closure_artifact_write_set_items i where i.write_set_id = w.id)
  ) from private.lcia_scope_closure_artifact_write_sets w where w.id = '${writeSetId}'::uuid;`;
}

function makeConcurrentDescriptors() {
  const base = `scope-closure/${CONCURRENT.closureCheckId}/`
    + '99999999-9999-4999-8999-999999999998/';
  const commonMetadata = (clientKey, artifactRole) => ({
    schemaVersion: 'lcia.scope-closure-artifact.v2',
    closureCheckId: CONCURRENT.closureCheckId,
    fileName: clientKey,
    artifactRole,
    retentionSeconds: 604800,
    contentArtifactManifestHash: 'b'.repeat(64),
  });
  return [
    {
      ordinal: 1,
      clientKey: 'bundle.json',
      artifactType: 'closure_bundle',
      artifactRole: 'closure_bundle',
      bucket: 'scope-closure-artifacts',
      objectPath: `${base}bundle.json`,
      mediaType: 'application/json',
      size: 101,
      checksumSha256: '5'.repeat(64),
      metadata: {
        ...commonMetadata('bundle.json', 'closure_bundle'),
        completeMachineResultClientKey: 'manifest.json',
      },
    },
    {
      ordinal: 2,
      clientKey: 'report.xlsx',
      artifactType: 'closure_report_xlsx',
      artifactRole: 'closure_report',
      bucket: 'scope-closure-artifacts',
      objectPath: `${base}report.xlsx`,
      mediaType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      size: 102,
      checksumSha256: '6'.repeat(64),
      metadata: commonMetadata('report.xlsx', 'closure_report'),
    },
    {
      ordinal: 3,
      clientKey: 'manifest.json',
      artifactType: 'closure_complete_machine_result',
      artifactRole: 'complete_machine_result',
      bucket: 'scope-closure-artifacts',
      objectPath: `${base}manifest.json`,
      mediaType: 'application/vnd.tiangong.scope-closure-manifest+json',
      size: 103,
      checksumSha256: '7'.repeat(64),
      metadata: commonMetadata(
        'manifest.json',
        'complete_machine_result',
      ),
    },
  ];
}

function createBody(ids, fixture, descriptors, digest) {
  return {
    p_closure_check_id: ids.closureCheckId,
    p_worker_job_id: ids.workerJobId,
    p_worker_lease_token: ids.workerLeaseToken,
    p_request_id: ids.requestId,
    p_contract_version: fixture.contractVersion,
    p_expected_descriptor_count: descriptors.length,
    p_descriptor_set_sha256: digest,
    p_required_primary_roles: fixture.requiredPrimaryRoles.fresh,
    p_staging_seconds: 3600,
    p_reused_from_check_id: null,
  };
}

function verifyAtomicSetup(environment, exact) {
  assertContract(
    runSql(environment.databaseUrl, `
      select count(*) = 1 and bool_and(tgdeferrable and tginitdeferred
        and tgenabled = 'O')
      from pg_trigger
      where tgrelid = 'auth.users'::regclass
        and tgfoid = 'private.sync_auth_users_to_private_users()'::regprocedure
        and not tgisinternal;
    `) === 't',
    'DEFERRED_AUTH_PROFILE_TRIGGER',
  );
  const residueSql = `
    select (select count(*) from auth.users where id = '${OWNER_ID}'::uuid)
      + (select count(*) from private.users where id = '${OWNER_ID}'::uuid)
      + (select count(*) from private.worker_jobs where id in (
          '${exact.workerJobId}'::uuid, '${CONCURRENT.workerJobId}'::uuid))
      + (select count(*) from private.lcia_scope_closure_checks where id in (
          '${exact.closureCheckId}'::uuid, '${CONCURRENT.closureCheckId}'::uuid));
  `;
  assertContract(runSql(environment.databaseUrl, residueSql) === '0', 'FIXTURE_NOT_CLEAN');
  // The invalid lease fails after the Auth/profile writes in the actual setup generator.
  const failed = spawnSync(
    'psql',
    [environment.databaseUrl, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=sqlstate'],
    {
      input: setupSql({ ...exact, workerLeaseToken: 'not-a-uuid' }),
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    },
  );
  assertContract(failed.status !== 0 && /\b22P02\b/.test(failed.stderr ?? ''), 'LATE_SETUP_FAILURE');
  assertContract(runSql(environment.databaseUrl, residueSql) === '0', 'ATOMIC_SETUP_RESIDUE');
}

async function main() {
  const fixtureBytes = await readFile(FIXTURE_PATH);
  const fixture = JSON.parse(fixtureBytes.toString('utf8'));
  const exact = fixture.example.ids;
  for (const key of [
    'closureCheckId',
    'workerJobId',
    'workerLeaseToken',
    'requestId',
  ]) {
    assertContract(UUID_RE.test(exact[key]), `FIXTURE_${key}`);
  }
  assertContract(
    canonicalJson({
      contractVersion: fixture.contractVersion,
      descriptors: fixture.example.descriptors,
    }) === fixture.canonicalization.descriptorSetCanonicalJson,
    'FIXTURE_CANONICAL_JSON',
  );
  assertContract(
    sha256(fixture.canonicalization.descriptorSetCanonicalJson)
      === fixture.canonicalization.descriptorSetSha256,
    'FIXTURE_DESCRIPTOR_DIGEST',
  );
  assertContract(
    SHA256_RE.test(fixture.canonicalization.descriptorSetSha256),
    'FIXTURE_DESCRIPTOR_DIGEST_SHAPE',
  );

  const environment = parseSupabaseEnvironment();
  verifyAtomicSetup(environment, exact);
  await verifyPostgrestIsolation(environment);
  let setupComplete = false;
  const evidence = {
    schemaVersion: 'lcia.scope-closure-staged-write-set-sql-proof.v1',
    fixtureSha256: sha256(fixtureBytes),
    descriptorSetSha256: fixture.canonicalization.descriptorSetSha256,
    exactFixtureDescriptorCount: fixture.example.descriptors.length,
    exactFixtureRequestCount: fixture.example.batches.length,
    sqlStoredStatusEqual: false,
    postgrestHelpersIsolated: false,
    statusForbiddenFieldsAbsent: false,
    concurrentRegisterSealSerialized: false,
    concurrentReadyRowsBeforeFinalize: null,
    timingsMs: {},
  };

  try {
    runSql(environment.databaseUrl, setupSql(exact));
    setupComplete = true;

    const created = await rpc(
      environment,
      'svc_lcia_scope_closure_artifact_write_set_create_v2',
      createBody(
        exact,
        fixture,
        fixture.example.descriptors,
        fixture.canonicalization.descriptorSetSha256,
      ),
    );
    exactKeys(created.value, ['ok', 'reused', 'data'], 'CREATE_TOP_LEVEL_SHAPE');
    exactKeys(
      created.value.data,
      fixture.rpc.status.fields,
      'CREATE_STATUS_SHAPE',
    );
    assertContract(
      created.value.ok === true
        && created.value.reused === false
        && created.value.data.status === 'registration_open'
        && created.value.data.uploadEligible === false
        && Object.keys(created.value.data.artifactMap).length === 0,
      'CREATE_STATE',
    );
    evidence.timingsMs.create = Number(created.elapsedMs.toFixed(3));

    let writeSet = created.value.data;
    let ordinalStart = 0;
    const registrationTimings = [];
    for (const batch of fixture.example.batches) {
      const items = batch.ordinals.map(
        (ordinal) => fixture.example.descriptors[ordinal - 1],
      );
      const registered = await rpc(
        environment,
        'svc_lcia_scope_closure_artifact_write_set_register_batch_v2',
        {
          p_write_set_id: writeSet.writeSetId,
          p_write_token: writeSet.writeToken,
          p_worker_job_id: exact.workerJobId,
          p_worker_lease_token: exact.workerLeaseToken,
          p_batch_id: batch.batchId,
          p_items: items,
        },
      );
      exactKeys(
        registered.value.data,
        fixture.rpc.status.fields,
        'REGISTER_STATUS_SHAPE',
      );
      assertContract(registered.value.ok === true, 'REGISTER_FAILED');
      writeSet = registered.value.data;
      ordinalStart += items.length;
      assertContract(
        writeSet.registeredDescriptorCount === ordinalStart
          && writeSet.uploadEligible === false,
        'REGISTER_COUNT_OR_AUTHORIZATION',
      );
      registrationTimings.push(Number(registered.elapsedMs.toFixed(3)));
    }
    evidence.timingsMs.registerBatches = registrationTimings;

    const replayBatch = fixture.example.batches[0];
    const replayed = await rpc(environment, 'svc_lcia_scope_closure_artifact_write_set_register_batch_v2', {
      p_write_set_id: writeSet.writeSetId, p_write_token: writeSet.writeToken,
      p_worker_job_id: exact.workerJobId, p_worker_lease_token: exact.workerLeaseToken,
      p_batch_id: replayBatch.batchId,
      p_items: replayBatch.ordinals.map((ordinal) => fixture.example.descriptors[ordinal - 1]),
    });
    assertContract(replayed.value.ok === true && replayed.value.reused === true
      && replayed.value.data.registeredDescriptorCount === fixture.example.descriptors.length, 'EXACT_BATCH_REPLAY');
    const stale = await rpc(environment, 'svc_lcia_scope_closure_artifact_write_set_status_v2', {
      p_closure_check_id: exact.closureCheckId, p_worker_job_id: exact.workerJobId,
      p_worker_lease_token: randomUUID(), p_request_id: exact.requestId,
    });
    assertContract(stale.value.ok === false && stale.value.code === 'worker_job_lease_invalid', 'STALE_LEASE_REJECTED');

    const preSealStatus = await rpc(
      environment,
      'svc_lcia_scope_closure_artifact_write_set_status_v2',
      {
        p_closure_check_id: exact.closureCheckId,
        p_worker_job_id: exact.workerJobId,
        p_worker_lease_token: exact.workerLeaseToken,
        p_request_id: exact.requestId,
      },
    );
    exactKeys(preSealStatus.value, ['ok', 'data'], 'STATUS_TOP_LEVEL_SHAPE');
    exactKeys(
      preSealStatus.value.data,
      fixture.rpc.status.fields,
      'STATUS_DATA_SHAPE',
    );
    evidence.statusForbiddenFieldsAbsent =
      fixture.rpc.status.forbiddenFields.every(
        (field) => !(field in preSealStatus.value.data),
      );
    assertContract(
      evidence.statusForbiddenFieldsAbsent,
      'STATUS_FORBIDDEN_FIELD',
    );

    const sealed = await rpc(
      environment,
      'svc_lcia_scope_closure_artifact_write_set_seal_v2',
      {
        p_write_set_id: writeSet.writeSetId,
        p_write_token: writeSet.writeToken,
        p_worker_job_id: exact.workerJobId,
        p_worker_lease_token: exact.workerLeaseToken,
      },
    );
    assertContract(
      sealed.value.ok === true
        && sealed.value.data.status === 'staging'
        && sealed.value.data.uploadEligible === true,
      'SEAL_STATE',
    );
    assertContract(
      canonicalJson(Object.keys(sealed.value.data.artifactMap).sort())
        === canonicalJson(
          fixture.example.descriptors.map((item) => item.clientKey).sort(),
        ),
      'SEAL_ARTIFACT_MAP',
    );
    evidence.timingsMs.seal = Number(sealed.elapsedMs.toFixed(3));

    const transportStatus = await rpc(
      environment,
      'svc_lcia_scope_closure_artifact_write_set_status_v2',
      {
        p_closure_check_id: exact.closureCheckId,
        p_worker_job_id: exact.workerJobId,
        p_worker_lease_token: exact.workerLeaseToken,
        p_request_id: exact.requestId,
      },
    );
    const storedStatus = JSON.parse(runSql(environment.databaseUrl, storedStatusSql(writeSet.writeSetId)));
    evidence.sqlStoredStatusEqual = Object.entries(storedStatus).every(
      ([key, value]) => canonicalJson(value) === canonicalJson(transportStatus.value.data[key]),
    );
    assertContract(evidence.sqlStoredStatusEqual, 'SQL_STORED_STATUS_MISMATCH');
    assertContract(storedStatus.descriptorSetSha256 === fixture.canonicalization.descriptorSetSha256
      && storedStatus.registeredDescriptorCount === fixture.example.descriptors.length
      && storedStatus.registeredBatchCount === fixture.example.batches.length
      && storedStatus.status === 'staging', 'STORED_FIXTURE_COUNTS_HASH_STATE');
    evidence.postgrestHelpersIsolated = true;

    const finalized = await rpc(
      environment,
      'svc_lcia_scope_closure_artifact_write_set_finalize_v2',
      {
        p_write_set_id: writeSet.writeSetId,
        p_write_token: writeSet.writeToken,
        p_worker_job_id: exact.workerJobId,
        p_worker_lease_token: exact.workerLeaseToken,
      },
    );
    assertContract(
      finalized.value.ok === true
        && finalized.value.data.status === 'ready'
        && finalized.value.data.uploadEligible === false,
      'FINALIZE_STATE',
    );
    evidence.timingsMs.finalize = Number(finalized.elapsedMs.toFixed(3));

    const concurrentDescriptors = makeConcurrentDescriptors();
    const concurrentDigest = sha256(canonicalJson({
      contractVersion: fixture.contractVersion,
      descriptors: concurrentDescriptors,
    }));
    const concurrentCreated = await rpc(
      environment,
      'svc_lcia_scope_closure_artifact_write_set_create_v2',
      createBody(
        CONCURRENT,
        fixture,
        concurrentDescriptors,
        concurrentDigest,
      ),
    );
    assertContract(concurrentCreated.value.ok === true, 'CONCURRENT_CREATE');
    const concurrentWriteSet = concurrentCreated.value.data;
    const firstBatch = await rpc(
      environment,
      'svc_lcia_scope_closure_artifact_write_set_register_batch_v2',
      {
        p_write_set_id: concurrentWriteSet.writeSetId,
        p_write_token: concurrentWriteSet.writeToken,
        p_worker_job_id: CONCURRENT.workerJobId,
        p_worker_lease_token: CONCURRENT.workerLeaseToken,
        p_batch_id: randomUUID(),
        p_items: concurrentDescriptors.slice(0, 2),
      },
    );
    assertContract(firstBatch.value.ok === true, 'CONCURRENT_FIRST_BATCH');

    const [racedRegistration, racedSeal] = await Promise.all([
      rpc(
        environment,
        'svc_lcia_scope_closure_artifact_write_set_register_batch_v2',
        {
          p_write_set_id: concurrentWriteSet.writeSetId,
          p_write_token: concurrentWriteSet.writeToken,
          p_worker_job_id: CONCURRENT.workerJobId,
          p_worker_lease_token: CONCURRENT.workerLeaseToken,
          p_batch_id: randomUUID(),
          p_items: concurrentDescriptors.slice(2),
        },
      ),
      rpc(
        environment,
        'svc_lcia_scope_closure_artifact_write_set_seal_v2',
        {
          p_write_set_id: concurrentWriteSet.writeSetId,
          p_write_token: concurrentWriteSet.writeToken,
          p_worker_job_id: CONCURRENT.workerJobId,
          p_worker_lease_token: CONCURRENT.workerLeaseToken,
        },
      ),
    ]);
    assertContract(
      racedRegistration.value.ok === true,
      'CONCURRENT_FINAL_BATCH',
    );
    let concurrentSeal = racedSeal.value;
    if (concurrentSeal.ok !== true) {
      assertContract(
        concurrentSeal.code === 'artifact_write_set_v2_incomplete',
        'CONCURRENT_SEAL_ERROR',
      );
      concurrentSeal = (
        await rpc(
          environment,
          'svc_lcia_scope_closure_artifact_write_set_seal_v2',
          {
            p_write_set_id: concurrentWriteSet.writeSetId,
            p_write_token: concurrentWriteSet.writeToken,
            p_worker_job_id: CONCURRENT.workerJobId,
            p_worker_lease_token: CONCURRENT.workerLeaseToken,
          },
        )
      ).value;
    }
    assertContract(
      concurrentSeal.ok === true
        && concurrentSeal.data.status === 'staging'
        && concurrentSeal.data.registeredDescriptorCount === 3,
      'CONCURRENT_SERIAL_OUTCOME',
    );
    evidence.concurrentRegisterSealSerialized = true;
    evidence.concurrentReadyRowsBeforeFinalize = Number(
      runSql(
        environment.databaseUrl,
        `select count(*) from private.worker_job_artifacts
         where job_id = '${CONCURRENT.workerJobId}'::uuid;`,
      ),
    );
    assertContract(
      evidence.concurrentReadyRowsBeforeFinalize === 0,
      'CONCURRENT_PARTIAL_READY',
    );
  } finally {
    if (setupComplete) {
      runSql(environment.databaseUrl, cleanupSql(exact));
    }
  }

  evidence.assertions = assertionCount;
  process.stdout.write(`${JSON.stringify(evidence, null, 2)}\n`);
}

main().catch((error) => {
  const code = error instanceof ContractError
    ? error.code
    : 'UNEXPECTED_CONTRACT_FAILURE';
  process.stderr.write(`${JSON.stringify({
    schemaVersion: 'lcia.scope-closure-staged-write-set-sql-error.v1',
    code,
  })}\n`);
  process.exitCode = 1;
});
