CREATE INDEX "lcia_scope_closure_checks_calculation_idx" ON "private"."lcia_scope_closure_checks" USING "btree" ("calculation_fingerprint") WHERE ("calculation_fingerprint" IS NOT NULL);
