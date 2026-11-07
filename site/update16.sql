-- Circle: run ONCE in a NEW, empty SQL Editor query (after update15.sql).
-- Live follows: lets the site hear "someone followed you" / "your request was accepted" instantly.
-- (Only rows you are allowed to see are sent to you; Supabase checks your existing follows rules.)
do $$ begin
  alter publication supabase_realtime add table public.follows;
exception when duplicate_object then null;
         when others then raise notice 'Could not add follows to realtime from SQL. Turn it on in Dashboard > Database > Replication (supabase_realtime) > follows.';
end $$;
