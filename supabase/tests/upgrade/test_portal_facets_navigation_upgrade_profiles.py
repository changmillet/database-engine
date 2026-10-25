#!/usr/bin/env python3
"""Offline qualification-boundary checks; never contact Docker or a database."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
SOURCE = Path(__file__).with_name('test_portal_facets_navigation_upgrade.py')
SPEC = importlib.util.spec_from_file_location('portal_upgrade_profiles', SOURCE)
assert SPEC and SPEC.loader
upgrade = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upgrade)


class UpgradeProfileTests(unittest.TestCase):
    def tearDown(self):
        upgrade.select_profile('864')

    def test_legacy_selection_retains_original_migration_and_four_targets(self):
        upgrade.select_profile('869')
        upgrade.select_profile('864')
        self.assertEqual(upgrade.CANDIDATE.name, '20261025052607_optimize_portal_facets_navigation.sql')
        self.assertEqual(len(upgrade.TARGETS), 4)
        self.assertIn('reject-original-v1-orphan', upgrade.CHECK_LABELS)
        self.assertIn('reject-facet-text-facts', upgrade.CHECK_LABELS)
        self.assertNotIn('reject-native-key-coverage', upgrade.CHECK_LABELS)
        self.assertEqual(upgrade.profile_candidate(None, 'unconstrained-legacy-base'), upgrade.CANDIDATE)

    def test_cas_selection_pins_exact_predecessor_ordered_bundle_and_two_targets(self):
        upgrade.select_profile('869')
        self.assertEqual(upgrade.TARGETS, ('display_sync_navigation_membership_v1', 'display_navigation_matched_versions_v1'))
        self.assertEqual(upgrade.profile_candidate(None, upgrade.CAS_BASE).name,
                         '20261025103800_activate_portal_flow_cas_fact.sql')
        self.assertEqual(upgrade.PROFILES['869']['prepare'].name, '20261025103759_prepare_portal_flow_cas_fact.sql')
        _, _, bundle = upgrade.load_candidate(upgrade.CAS_BASE, None)
        self.assertIsInstance(bundle, upgrade.NativeStatements)
        self.assertTrue(bundle.prepare and bundle.activate)
        with self.assertRaises(ValueError):
            upgrade.load_candidate(upgrade.CAS_BASE, None, upgrade.PROFILES['869']['candidate'])
        for base in ('main', '6a88083', '0' * 40):
            with self.assertRaises(ValueError):
                upgrade.profile_candidate(None, base)
        with self.assertRaises(ValueError):
            upgrade.profile_candidate(upgrade.PROFILES['864']['candidate'], upgrade.CAS_BASE)
        with self.assertRaises(ValueError):
            upgrade.select_profile('auto')

    def test_guard_extraction_cannot_accept_other_profile_or_missing_guard(self):
        legacy = ['do $display_facets_cutover_guard$begin null;end$display_facets_cutover_guard$;']
        cas = ['do $display_flow_cas_preflight$begin null;end$display_flow_cas_preflight$;']
        for name, accepted, rejected in (('864', legacy, cas), ('869', cas, legacy)):
            upgrade.select_profile(name)
            self.assertEqual(upgrade.cutover_guard(accepted), accepted[0])
            for invalid in ([], rejected, accepted * 2):
                with self.assertRaises(ValueError):
                    upgrade.cutover_guard(invalid)

    def test_sql_boundary_rejects_partial_or_extra_transactions(self):
        good = "begin;do $guard$begin perform ';';end$guard$;commit;"
        self.assertEqual(len(upgrade.migration_statements(good)), 1)
        for invalid in ('begin;select 1;', 'select 1;commit;', 'begin;rollback;commit;'):
            with self.assertRaises(ValueError):
                upgrade.migration_statements(invalid)

    def test_named_guard_is_required_before_any_ddl(self):
        upgrade.select_profile('869')
        guard = 'do $display_flow_cas_preflight$begin null;end$display_flow_cas_preflight$;'
        ddl = 'create or replace function private.example() returns void language sql as $$select;$$;'
        upgrade.require_pre_ddl_guard(['set local lock_timeout=\'5s\';', guard, ddl])
        for invalid in ([ddl, guard], [ddl]):
            with self.assertRaises(ValueError):
                upgrade.require_pre_ddl_guard(invalid)


if __name__ == '__main__':
    unittest.main()
