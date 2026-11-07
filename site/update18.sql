-- Circle: run ONCE in a NEW, empty SQL Editor query (after update17.sql).
-- Customer service: users chat with a helper bot and with YOUR support team.
--   * Bot answers come from the table support_bot. Add or edit rows any time in Table Editor.
--   * You (staff) answer from the app: Settings > Customer service > Staff inbox.

-- 1) Who is support staff. >>> CHANGE the email below to the email you sign in with. <<<
create table if not exists support_staff(user_id uuid primary key references auth.users on delete cascade);
alter table support_staff enable row level security;   -- no policies: only this SQL editor can change it
insert into support_staff(user_id)
  select id from auth.users where lower(email)=lower('m4sterjade9@gmail.com')
  on conflict do nothing;

create or replace function is_support() returns boolean
language sql security definer stable set search_path=public as
$$ select exists(select 1 from support_staff where user_id=auth.uid()) $$;
grant execute on function is_support() to authenticated;

-- 2) Messages (one conversation per customer)
create table if not exists support_messages(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  sender text not null check (sender in ('user','staff','bot')),
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now());
create index if not exists support_messages_user_idx on support_messages(user_id, created_at);
alter table support_messages enable row level security;
drop policy if exists "support read" on support_messages;
drop policy if exists "support staff reply" on support_messages;
create policy "support read" on support_messages for select to authenticated
  using (user_id=auth.uid() or is_support());
create policy "support staff reply" on support_messages for insert to authenticated
  with check (sender='staff' and is_support());

-- 3) Bot answers. keywords = words/phrases separated by commas; the first match wins (higher priority first).
create table if not exists support_bot(
  id serial primary key,
  keywords text not null,
  answer text not null,
  priority int not null default 0,
  active boolean not null default true);
alter table support_bot enable row level security;
drop policy if exists "bot read" on support_bot;
create policy "bot read" on support_bot for select to anon, authenticated using (active);

insert into support_bot(keywords,answer)
select * from (values
 ('password,forgot,reset','Forgot your password? Sign out, choose “Forgot password?” on the sign-in page and we’ll email you a reset link. Check your spam folder too.'),
 ('username,rename,change name','Open Settings > Account and security. You can change your username once every 15 days (3–20 characters: letters, numbers, _ and .).'),
 ('private,privacy,hide my posts','Open Settings > Privacy and safety and turn on Private account. Only followers you approve will see your posts and stories.'),
 ('block,harass,bother,stalk','Open their profile and tap Block. They won’t be able to see your posts, follow you or message you. You can also Report a post from under the post.'),
 ('delete account,delete my account,remove account','Open Settings > Delete account. This permanently removes your profile, posts, messages and follows and cannot be undone.'),
 ('report,abuse,spam,scam,fake','Tap Report under a post and tell us why. Our team reviews reports. For something urgent, leave a message here and a person will check.'),
 ('story,stories,archive','Stories last 24 hours, then move to Your activity where you can share them again. Archived posts can be restored there too.'),
 ('note,music','Notes show for 24 hours. Tap the music button to pick a free track or upload your own. Tap your note to play it, and tap it again to close.'),
 ('follow,follower,request','On a private account people send a request that you accept or decline in Notifications. Open the followers or following list from a profile.'),
 ('verify,verified,badge','Verification badges are given by our team. Leave a message here describing your account and a person will look at it.'),
 ('human,agent,person,staff','Sure! Write your question here and a member of our support team will reply in this chat.')
) as v(k,a)
where not exists (select 1 from support_bot);

-- 4) Sending a message (also gives the bot reply). Limits: 20 messages per hour.
create or replace function support_send(p_body text) returns void
language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); b text:=left(trim(coalesce(p_body,'')),1000); ans text;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  if b='' then raise exception 'Write a message first.'; end if;
  if (select count(*) from support_messages where user_id=uid and sender='user' and created_at>now()-interval '1 hour')>=20 then
    raise exception 'You are sending messages too fast. Please wait a little.'; end if;
  insert into support_messages(user_id,sender,body) values(uid,'user',b);
  -- stay quiet while a real person is already helping (staff replied in the last 12 hours)
  if exists(select 1 from support_messages where user_id=uid and sender='staff' and created_at>now()-interval '12 hours') then return; end if;
  select bt.answer into ans from support_bot bt
   where bt.active and exists(select 1 from unnest(string_to_array(lower(bt.keywords),',')) k
                              where trim(k)<>'' and position(trim(k) in lower(b))>0)
   order by bt.priority desc, bt.id limit 1;
  if ans is not null then
    insert into support_messages(user_id,sender,body) values(uid,'bot',ans);
  elsif not exists(select 1 from support_messages where user_id=uid and sender='bot' and created_at>now()-interval '6 hours') then
    insert into support_messages(user_id,sender,body) values(uid,'bot','Thanks for your message! Our support team will reply here as soon as they can.');
  end if;
end $$;
grant execute on function support_send(text) to authenticated;

-- 5) Live updates
do $$ begin alter publication supabase_realtime add table public.support_messages;
exception when duplicate_object then null; when others then null; end $$;
