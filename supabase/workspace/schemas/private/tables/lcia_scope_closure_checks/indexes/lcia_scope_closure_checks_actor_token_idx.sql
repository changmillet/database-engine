CREATE INDEX "lcia_scope_closure_checks_actor_token_idx" ON "private"."lcia_scope_closure_checks" USING "btree" ("requested_by", "request_idempotency_token", "created_at", "id");
