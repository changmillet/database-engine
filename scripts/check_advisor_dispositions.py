#!/usr/bin/env python3
"""Validate the public exact-object disposition contract without querying a DB.

Optional --snapshot reads a private CLI Advisor snapshot for exact baseline
correspondence; operating counts/sizes/counters are never copied or printed.
"""
from __future__ import annotations
import argparse
import collections
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
FIXTURE=ROOT/'supabase/tests/fixtures/20261006_advisor_dispositions.json'
PRIVATE_KEYS={'baselineCardinality','baselineTable','reportedIndexBytes','observedIndexScans',
 'pg_managed_index_bytes','idx_scan_in_inventory','table_estimated_rows','request_id','requestId'}


def private_fields(value):
    if isinstance(value,dict):
        bad=PRIVATE_KEYS&value.keys()
        if bad:raise ValueError('Public fixture contains operating fields: '+','.join(sorted(bad)))
        for child in value.values():private_fields(child)
    elif isinstance(value,list):
        for child in value:private_fields(child)


def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--snapshot',type=Path)
    a=p.parse_args();d=json.loads(FIXTURE.read_text());private_fields(d)
    records=d['records'];keys=[r['cacheKey'] for r in records]
    if len(records)!=d['baselineCount'] or len(keys)!=len(set(keys)):
        raise ValueError('Missing/duplicate baseline correspondence')
    classes=d['classificationRules'];sources=d['sourceEvidence']
    for r in records:
        if r['disposition'] not in ('fixed','retained','not-applicable'):raise ValueError('Unknown disposition')
        if not r.get('object') or not r.get('rule'):raise ValueError('Object/rule identity absent')
        common=classes.get(r['classification'],{})
        if not r.get('reason',common.get('reason')) or not r.get('reviewTrigger',common.get('reviewTrigger')):
            raise ValueError('Reason/re-review condition absent: '+r['object'])
        for ref in r.get('sourceEvidence',[]):
            if ref not in sources:raise ValueError('Unbound source evidence')
        if r.get('retentionState')=='pending_final_source_demand_dependency_review':
            raise ValueError('Unresolved current-cycle classification')
    for e in sources.values():
        if not e['path'] or not e['line'] or len(e['sha256'])!=64:raise ValueError('Malformed source evidence')
    api={r['object'] for r in records if r['classification']=='manifest_bound_api_facade'}
    anon={r['object'] for r in records if r.get('role')=='anon'}
    if len(api)!=d['uniqueApiDefiners'] or len(anon)!=d['anonDefinerOverlap']:
        raise ValueError('Definer overlap does not reconcile')
    if d['boundedReviewSummary']['current_cycle_unresolved_todos']!=0:
        raise ValueError('Current-cycle review is unfinished')
    if a.snapshot:
        snapshot=json.loads(a.snapshot.read_text())
        if not isinstance(snapshot,list):raise ValueError('Expected private CLI Advisor list')
        observed=[x['cache_key'] for x in snapshot]
        if len(observed)!=len(set(observed)) or set(observed)!=set(keys):
            raise ValueError('Snapshot/object correspondence differs; investigate without overwriting exceptions')
    print(json.dumps({'records':len(records),'uniqueApiDefiners':len(api),'anonOverlap':len(anon),
       'dispositions':dict(collections.Counter(r['disposition'] for r in records)),
       'currentCycleTodos':0,'privateOperatingFields':False},indent=2))
    return 0


if __name__=='__main__':raise SystemExit(main())
