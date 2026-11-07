-- Circle: run ONCE in a NEW, empty SQL Editor query (after update13.sql).
-- Adds: username change with a 15-day cooldown, enforced by the database itself.

alter table profiles add column if not exists username_changed_at timestamptz;

create or replace function profiles_username_guard() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  -- Only apply to changes made by a signed-in user (SQL Editor / dashboard edits are not limited).
  if auth.uid() is not null then
    if new.username is distinct from old.username then
      new.username := trim(coalesce(new.username,''));
      if new.username !~ '^[A-Za-z0-9_.]{3,20}$' then
        raise exception 'Usernames are 3-20 characters: letters, numbers, _ and . only.';
      end if;
      if lower(new.username) <> lower(old.username)
         and exists(select 1 from profiles p where lower(p.username)=lower(new.username) and p.id<>old.id) then
        raise exception 'That username is taken.';
      end if;
      if old.username_changed_at is not null and old.username_changed_at > now() - interval '15 days' then
        raise exception 'You can change your username again on %.', to_char(old.username_changed_at + interval '15 days', 'Mon DD, YYYY');
      end if;
      new.username_changed_at := now();
    else
      -- the change time can only be set by the rule above, never directly by the app
      new.username_changed_at := old.username_changed_at;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_username_guard on profiles;
create trigger profiles_username_guard before update on profiles
  for each row execute function profiles_username_guard();

-- Make sure signed-in users are allowed to update their own username column.
grant update (username) on profiles to authenticated;
notify pgrst, 'reload schema';
