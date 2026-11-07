-- Circle: run ONCE in a NEW, empty SQL Editor query (after update16.sql).
-- Music library: lets posts, stories and notes use the built-in tracks in /music (no upload needed).
-- Music links may now be EITHER your own storage file OR a built-in track like music/lofi-chill.mp3.
do $$
declare
  tbl text;
  pat constant text := '^(https://ctrjhszfpwkpzirhedbb\.supabase\.co/storage/v1/object/public/media/|music/[a-z0-9-]+\.mp3$)';
begin
  foreach tbl in array array['posts','stories','notes'] loop
    if exists(select 1 from information_schema.columns
              where table_schema='public' and table_name=tbl and column_name='music_url') then
      execute format('alter table public.%I drop constraint if exists %I', tbl, tbl||'_music_url_own_storage');
      execute format('alter table public.%I add constraint %I check (music_url is null or music_url = '''' or music_url ~ %L) not valid',
                     tbl, tbl||'_music_url_own_storage', pat);
    end if;
  end loop;
end $$;
