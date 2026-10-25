CREATE INDEX "lcia_scope_closure_scan_calculation_idx" ON "private"."lcia_scope_closure_scan_executions" USING "btree" ("calculation_fingerprint") WHERE ("calculation_fingerprint" IS NOT NULL);
