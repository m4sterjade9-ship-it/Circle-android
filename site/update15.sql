-- Circle: run ONCE in a NEW, empty SQL Editor query (after update14.sql).
-- Security hardening:
--   1) media/music links must point at YOUR storage (stops tracking links and bypassed uploads)
--   2) usernames are unique at the database level (no race-condition duplicates)
--   3) the media bucket only accepts images/videos/audio up to 20 MB (no SVG/HTML files)
--   4) groups: you can only add people you are connected with (accepted follow either way)
--   5) message flood limits

-- 1) Links must start with this project's public media URL. NOT VALID = old rows are left alone, new/edited rows are checked.
do $$
declare
  tbl text; col text;
  pat constant text := '^https://ctrjhszfpwkpzirhedbb\.supabase\.co/storage/v1/object/public/media/';
begin
  for tbl, col in
    select v.a, v.b from (values
      ('posts','media_url'),('posts','music_url'),
      ('stories','media_url'),('stories','music_url'),
      ('notes','music_url'),
      ('messages','media_url'),('group_messages','media_url')
    ) as v(a,b)
  loop
    if exists(select 1 from information_schema.columns
              where table_schema='public' and table_name=tbl and column_name=col) then
      execute format('alter table public.%I drop constraint if exists %I', tbl, tbl||'_'||col||'_own_storage');
      execute format('alter table public.%I add constraint %I check (%I is null or %I = '''' or %I ~ %L) not valid',
                     tbl, tbl||'_'||col||'_own_storage', col, col, col, pat);
    end if;
  end loop;
end $$;

-- 2) Unique usernames, case-insensitive.
do $$
begin
  create unique index if not exists profiles_username_lower_uidx on public.profiles (lower(username));
exception when unique_violation then
  raise notice 'Skipped the unique-username index because duplicates already exist. Find them with: select lower(username), count(*) from profiles group by 1 having count(*) > 1;';
end $$;

-- 3) Storage bucket limits (if this is refused, set the same in Dashboard > Storage > media > Edit bucket).
do $$
begin
  update storage.buckets
     set file_size_limit = 20971520,
         allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','image/heic','image/heif','image/avif','video/*','audio/*']
   where id = 'media';
exception when others then
  raise notice 'Could not update the bucket from SQL. Set the size limit (20 MB) and allowed types in the Storage dashboard instead.';
end $$;

-- 4) Groups: only add people you are connected with.
create or replace function create_group(p_name text, p_members uuid[]) returns uuid
language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); gid uuid; m uuid;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  if char_length(trim(coalesce(p_name,''))) < 1 then raise exception 'Give the group a name.'; end if;
  insert into groups(name,owner) values(left(trim(p_name),60),uid) returning id into gid;
  insert into group_members(group_id,user_id,role) values(gid,uid,'owner');
  for m in select distinct x from unnest(coalesce(p_members,'{}')) x limit 49 loop
    if m<>uid and exists(select 1 from profiles where id=m) and not is_blocked(m,uid)
       and exists(select 1 from follows f where f.status='accepted'
                  and ((f.follower=uid and f.followee=m) or (f.follower=m and f.followee=uid))) then
      insert into group_members(group_id,user_id) values(gid,m) on conflict do nothing; end if;
  end loop;
  return gid;
end $$;
revoke execute on function create_group(text,uuid[]) from public, anon;
grant execute on function create_group(text,uuid[]) to authenticated;

-- 5) Flood limits: 30 messages per minute per person (direct and group).
create index if not exists messages_sender_created_idx on messages(sender, created_at desc);
create index if not exists group_messages_sender_created_idx on group_messages(sender, created_at desc);

create or replace function limit_message_rate() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is not null and
     (select count(*) from messages where sender=new.sender and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'You are sending messages too fast. Please wait a moment.';
  end if;
  return new;
end $$;
drop trigger if exists messages_rate_limit on messages;
create trigger messages_rate_limit before insert on messages for each row execute function limit_message_rate();

create or replace function limit_group_message_rate() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is not null and
     (select count(*) from group_messages where sender=new.sender and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'You are sending messages too fast. Please wait a moment.';
  end if;
  return new;
end $$;
drop trigger if exists group_messages_rate_limit on group_messages;
create trigger group_messages_rate_limit before insert on group_messages for each row execute function limit_group_message_rate();

notify pgrst, 'reload schema';
