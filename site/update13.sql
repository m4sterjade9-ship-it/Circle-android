-- Circle: run ONCE in a NEW, empty SQL Editor query (after update12.sql).
-- Adds: Notes, music on notes/stories/posts, message requests/archive/mute/restrict, group chats.

-- 1) Music on stories and posts
alter table stories add column if not exists music_url text;
alter table stories add column if not exists music_title text;
alter table posts add column if not exists music_url text;
alter table posts add column if not exists music_title text;

-- 2) Notes (short status shown at the top of Messages for 24 hours, optional music)
create table if not exists notes(
  user_id uuid primary key references profiles on delete cascade,
  body text not null default '' check(char_length(body)<=60),
  music_url text, music_title text,
  created_at timestamptz default now());
alter table notes enable row level security;
drop policy if exists "notes read" on notes; drop policy if exists "notes add own" on notes;
drop policy if exists "notes edit own" on notes; drop policy if exists "notes delete own" on notes;
create policy "notes read" on notes for select to authenticated
  using(user_id=auth.uid() or (created_at>now()-interval '24 hours' and can_see(user_id)));
create policy "notes add own" on notes for insert to authenticated with check(user_id=auth.uid());
create policy "notes edit own" on notes for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid() and created_at<=now()+interval '1 minute');
create policy "notes delete own" on notes for delete to authenticated using(user_id=auth.uid());

-- 3) Per-chat settings: archive, mute, restrict, accepted request (private to you)
create table if not exists chat_settings(
  user_id uuid not null references profiles on delete cascade,
  peer uuid not null references profiles on delete cascade,
  archived boolean not null default false, muted boolean not null default false,
  restricted boolean not null default false, accepted boolean not null default false,
  primary key(user_id,peer));
alter table chat_settings enable row level security;
drop policy if exists "chat settings own" on chat_settings;
create policy "chat settings own" on chat_settings for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

-- Inbox with folders. A chat is a "request" if you never replied, don't follow them, and haven't accepted - or if you restricted them.
create or replace function inbox2() returns table(peer uuid, last_body text, last_type text, last_at timestamptz, last_sender uuid, unread bigint, archived boolean, muted boolean, restricted boolean, is_request boolean)
language sql stable security invoker set search_path=public as $$
  with m as (select case when sender=auth.uid() then recipient else sender end as p, body, media_type, created_at, sender
             from messages where sender=auth.uid() or recipient=auth.uid()),
  l as (select distinct on (p) p, body, media_type, created_at, sender from m order by p, created_at desc)
  select l.p, l.body, l.media_type, l.created_at, l.sender,
    (select count(*) from messages x where x.sender=l.p and x.recipient=auth.uid() and x.read_at is null),
    coalesce(s.archived,false), coalesce(s.muted,false), coalesce(s.restricted,false),
    (coalesce(s.restricted,false) or (not coalesce(s.accepted,false)
      and not exists(select 1 from messages y where y.sender=auth.uid() and y.recipient=l.p)
      and not exists(select 1 from follows f where f.follower=auth.uid() and f.followee=l.p and f.status='accepted')))
  from l left join chat_settings s on s.user_id=auth.uid() and s.peer=l.p
  order by l.created_at desc $$;
revoke execute on function inbox2() from public, anon;
grant execute on function inbox2() to authenticated;

-- 4) Group chats
create table if not exists groups(
  id uuid primary key default gen_random_uuid(),
  name text not null check(char_length(name) between 1 and 60),
  owner uuid not null references profiles on delete cascade,
  created_at timestamptz default now());
create table if not exists group_members(
  group_id uuid not null references groups on delete cascade,
  user_id uuid not null references profiles on delete cascade,
  role text not null default 'member', primary key(group_id,user_id));
create table if not exists group_messages(
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups on delete cascade,
  sender uuid not null references profiles on delete cascade,
  body text not null default '' check(char_length(body)<=2000),
  media_url text, media_type text,
  created_at timestamptz default now());
create index if not exists group_messages_idx on group_messages(group_id,created_at desc);
create index if not exists group_members_user_idx on group_members(user_id);
create or replace function is_member(gid uuid) returns boolean language sql security definer stable set search_path=public as
$$ select exists(select 1 from group_members where group_id=gid and user_id=auth.uid()) $$;
alter table groups enable row level security; alter table group_members enable row level security; alter table group_messages enable row level security;
drop policy if exists "groups read" on groups; drop policy if exists "gm read" on group_members; drop policy if exists "gm leave" on group_members;
drop policy if exists "gmsg read" on group_messages; drop policy if exists "gmsg send" on group_messages; drop policy if exists "gmsg delete own" on group_messages;
create policy "groups read" on groups for select to authenticated using(is_member(id));
create policy "gm read" on group_members for select to authenticated using(is_member(group_id));
create policy "gm leave" on group_members for delete to authenticated using(user_id=auth.uid());
create policy "gmsg read" on group_messages for select to authenticated using(is_member(group_id));
create policy "gmsg send" on group_messages for insert to authenticated with check(sender=auth.uid() and is_member(group_id));
create policy "gmsg delete own" on group_messages for delete to authenticated using(sender=auth.uid());
revoke insert, update, delete on groups from authenticated, anon;
revoke insert, update, delete on group_members from authenticated, anon;
grant delete on group_members to authenticated;
create or replace function create_group(p_name text, p_members uuid[]) returns uuid
language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); gid uuid; m uuid;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  if char_length(trim(coalesce(p_name,''))) < 1 then raise exception 'Give the group a name.'; end if;
  insert into groups(name,owner) values(left(trim(p_name),60),uid) returning id into gid;
  insert into group_members(group_id,user_id,role) values(gid,uid,'owner');
  for m in select distinct x from unnest(coalesce(p_members,'{}')) x limit 49 loop
    if m<>uid and exists(select 1 from profiles where id=m) and not is_blocked(m,uid) then
      insert into group_members(group_id,user_id) values(gid,m) on conflict do nothing; end if;
  end loop;
  return gid;
end $$;
revoke execute on function create_group(text,uuid[]) from public, anon;
grant execute on function create_group(text,uuid[]) to authenticated;
do $$ begin alter publication supabase_realtime add table group_messages; exception when others then null; end $$;
notify pgrst, 'reload schema';
