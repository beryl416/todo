-- Todo app storage inside the shared Supabase project (ref hqyucrsqxvzwtyewxqhi),
-- which other apps also use. Nothing here touches their tables.
--
-- Everything lives in the private "todo" schema, which the API does not expose.
-- The apps reach it only through public.todo_pull and public.todo_push, and both
-- require the sync key. The database keeps only the SHA-256 hash of that key.
--
-- Apply with:  supabase db query --linked --project-ref <ref> -f supabase/todo.sql
-- (No migration history is written, same as the other apps in this project.)

create schema if not exists todo;
revoke all on schema todo from public, anon, authenticated;

create table if not exists todo.spaces (
  key_hash   text primary key,
  created_at timestamptz not null default now()
);

create sequence if not exists todo.rev_seq;

create table if not exists todo.items (
  space      text not null references todo.spaces (key_hash) on delete cascade,
  id         uuid not null,
  title      text not null default '',
  scope      text not null default 'day' check (scope in ('day', 'week', 'month')),
  day        date not null,                    -- the day, or the first day of the week / month
  done       boolean not null default false,
  starred    boolean not null default false,
  position   double precision not null default 0,
  deleted    boolean not null default false,   -- tombstone so other devices learn about deletes
  updated_at bigint not null,                  -- client clock in ms; the newest write wins
  rev        bigint not null default nextval('todo.rev_seq'),  -- server order for incremental pulls
  primary key (space, id)
);

-- Added after the first version: daily, weekly and monthly lists.
alter table todo.items add column if not exists scope text not null default 'day';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'items_scope_check' and conrelid = 'todo.items'::regclass) then
    alter table todo.items add constraint items_scope_check check (scope in ('day', 'week', 'month'));
  end if;
end
$$;

create index if not exists items_space_rev on todo.items (space, rev);

alter table todo.spaces enable row level security;
alter table todo.items  enable row level security;

-- Returns the space for a sync key, or fails.
create or replace function todo.space_for(p_key text)
returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
  h text;
begin
  if p_key is null or char_length(p_key) < 32 then
    raise exception 'invalid sync key' using errcode = '28000';
  end if;
  h := encode(sha256(convert_to(p_key, 'UTF8')), 'hex');
  if not exists (select 1 from todo.spaces s where s.key_hash = h) then
    raise exception 'invalid sync key' using errcode = '28000';
  end if;
  return h;
end
$$;

revoke all on function todo.space_for(text) from public, anon, authenticated;

-- Items changed after p_since. p_since = 0 returns every live item (a full snapshot).
-- The result is {"rev": <newest rev in the space>, "items": [...]}.
create or replace function public.todo_pull(p_key text, p_since bigint default 0)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  s text := todo.space_for(p_key);
begin
  return jsonb_build_object(
    'rev', coalesce((select max(i.rev) from todo.items i where i.space = s), 0),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id,
               'title', i.title,
               'scope', i.scope,
               'day', to_char(i.day, 'YYYY-MM-DD'),
               'done', i.done,
               'starred', i.starred,
               'position', i.position,
               'deleted', i.deleted,
               'updated_at', i.updated_at)
             order by i.rev)
      from todo.items i
      where i.space = s
        and i.rev > coalesce(p_since, 0)
        and (coalesce(p_since, 0) > 0 or not i.deleted)
    ), '[]'::jsonb)
  );
end
$$;

-- Upserts a batch of items (deletes are items with "deleted": true).
-- A write older than what the server already has is ignored.
create or replace function public.todo_push(p_key text, p_items jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  s text := todo.space_for(p_key);
  n integer;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad batch' using errcode = '22023';
  end if;

  insert into todo.items as t (space, id, title, scope, day, done, starred, position, deleted, updated_at)
  select s,
         (x ->> 'id')::uuid,
         left(coalesce(x ->> 'title', ''), 1000),
         coalesce(x ->> 'scope', 'day'),
         (x ->> 'day')::date,
         coalesce((x ->> 'done')::boolean, false),
         coalesce((x ->> 'starred')::boolean, false),
         coalesce((x ->> 'position')::double precision, 0),
         coalesce((x ->> 'deleted')::boolean, false),
         (x ->> 'updated_at')::bigint
  from jsonb_array_elements(p_items) as x
  on conflict (space, id) do update
    set title      = excluded.title,
        scope      = excluded.scope,
        day        = excluded.day,
        done       = excluded.done,
        starred    = excluded.starred,
        position   = excluded.position,
        deleted    = excluded.deleted,
        updated_at = excluded.updated_at,
        rev        = nextval('todo.rev_seq')
    where t.updated_at <= excluded.updated_at;
  get diagnostics n = row_count;

  -- Forget tombstones after 90 days; a device away that long does a full pull anyway.
  delete from todo.items i
  where i.space = s and i.deleted
    and i.updated_at < (extract(epoch from now()) * 1000)::bigint - 90::bigint * 86400000;

  return jsonb_build_object('applied', n);
end
$$;

revoke all on function public.todo_pull(text, bigint) from public;
revoke all on function public.todo_push(text, jsonb) from public;
grant execute on function public.todo_pull(text, bigint) to anon, authenticated;
grant execute on function public.todo_push(text, jsonb) to anon, authenticated;
