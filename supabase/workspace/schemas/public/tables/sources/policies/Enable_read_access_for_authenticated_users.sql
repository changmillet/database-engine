CREATE POLICY "Enable read access for authenticated users" ON "public"."sources" FOR SELECT TO "authenticated" USING ((("state_code" >= 100) OR (( SELECT "auth"."uid"() AS "uid") = "user_id") OR (EXISTS ( SELECT 1
   FROM "private"."roles"
  WHERE (("roles"."team_id" = "sources"."team_id") AND (("roles"."role")::"text" = ANY (ARRAY['admin'::"text", 'member'::"text", 'owner'::"text"])) AND ("roles"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))) OR (("state_code" = 20) AND ((EXISTS ( SELECT 1
   FROM "private"."roles"
  WHERE (("roles"."team_id" = '00000000-0000-0000-0000-000000000000'::"uuid") AND (("roles"."role")::"text" = 'review-admin'::"text") AND ("roles"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))) OR (("id", ("version")::"text") IN ( SELECT ((("r"."json" -> 'data'::"text") ->> 'id'::"text"))::"uuid" AS "uuid",
    (("r"."json" -> 'data'::"text") ->> 'version'::"text")
   FROM "private"."reviews" "r"
  WHERE (("r"."state_code" > 0) AND ("r"."reviewer_id" @> "jsonb_build_array"((( SELECT "auth"."uid"() AS "uid"))::"text"))))) OR
CASE
    WHEN (EXISTS ( SELECT 1
       FROM "private"."reviews" "r"
      WHERE ("r"."reviewer_id" @> "jsonb_build_array"((( SELECT "auth"."uid"() AS "uid"))::"text")))) THEN (("jsonb_array_length"("reviews") > 0) AND (ARRAY( SELECT (("review_item"."value" ->> 'id'::"text"))::"uuid" AS "uuid"
       FROM "jsonb_array_elements"("sources"."reviews") "review_item"("value")) && ( SELECT "array_agg"("r"."id") AS "array_agg"
       FROM "private"."reviews" "r"
      WHERE ("r"."reviewer_id" @> "jsonb_build_array"((( SELECT "auth"."uid"() AS "uid"))::"text")))))
    ELSE false
END))));
