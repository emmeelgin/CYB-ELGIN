-- Run this script in the Supabase SQL Editor for the class assignments board.
-- In Supabase Authentication, create a teacher account first. Then replace the
-- example email below with that account's email and run the final INSERT.

create table if not exists public.teachers (
    user_id uuid primary key references auth.users (id) on delete cascade,
    added_at timestamptz not null default now()
);

create table if not exists public.student_roster (
    student_id text primary key,
    first_name text not null,
    last_name text not null,
    added_at timestamptz not null default now()
);

create table if not exists public.assignments (
    id uuid primary key default gen_random_uuid(),
    title text not null check (char_length(title) between 1 and 120),
    course text not null default 'Class',
    description text not null default '',
    resource_url text not null default '',
    status text not null default 'draft' check (status in ('draft', 'published')),
    position integer not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.assignments
add column if not exists due_date date;

create table if not exists public.student_progress (
    student_id text not null,
    assignment_id uuid not null references public.assignments (id) on delete cascade,
    completed boolean not null default false,
    updated_at timestamptz not null default now(),
    primary key (student_id, assignment_id)
);

alter table public.student_progress enable row level security;
revoke all on public.student_progress from public, anon, authenticated;

create or replace function public.student_id_for_name(p_first_name text, p_last_name text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
    normalized_first text := regexp_replace(lower(trim(coalesce(p_first_name, ''))), '\s+', ' ', 'g');
    normalized_last text := regexp_replace(lower(trim(coalesce(p_last_name, ''))), '\s+', ' ', 'g');
begin
    if normalized_first = '' or normalized_last = ''
       or char_length(normalized_first) > 50 or char_length(normalized_last) > 50 then
        raise exception 'Enter a first and last name (50 characters maximum each).';
    end if;
    return md5(normalized_first || chr(31) || normalized_last);
end;
$$;

create or replace function public.get_student_progress(p_first_name text, p_last_name text)
returns table (assignment_id uuid, completed boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
    resolved_student_id text := public.student_id_for_name(p_first_name, p_last_name);
begin
    if not exists (
        select 1 from public.student_roster
        where student_id = resolved_student_id
    ) then
        raise exception 'Name not found on the student roster. Ask your teacher to add it.';
    end if;

    return query
    select progress.assignment_id, progress.completed
    from public.student_progress as progress
    where progress.student_id = resolved_student_id;
end;
$$;

create or replace function public.save_student_progress(
    p_first_name text,
    p_last_name text,
    p_assignment_id uuid,
    p_completed boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    resolved_student_id text := public.student_id_for_name(p_first_name, p_last_name);
begin
    if not exists (
        select 1 from public.student_roster
        where student_id = resolved_student_id
    ) then
        raise exception 'Name not found on the student roster. Ask your teacher to add it.';
    end if;

    if p_completed is null then
        raise exception 'Completion status is required.';
    end if;

    if not exists (
        select 1 from public.assignments
        where id = p_assignment_id and status = 'published'
    ) then
        raise exception 'That assignment is not currently published.';
    end if;

    insert into public.student_progress (student_id, assignment_id, completed)
    values (resolved_student_id, p_assignment_id, p_completed)
    on conflict (student_id, assignment_id) do update
    set completed = excluded.completed, updated_at = now();
end;
$$;

revoke all on function public.student_id_for_name(text, text) from public, anon, authenticated;
revoke all on function public.get_student_progress(text, text) from public, anon, authenticated;
revoke all on function public.save_student_progress(text, text, uuid, boolean) from public, anon, authenticated;
grant execute on function public.get_student_progress(text, text) to anon, authenticated;
grant execute on function public.save_student_progress(text, text, uuid, boolean) to anon, authenticated;

create or replace function public.is_class_teacher()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.teachers
        where user_id = (select auth.uid())
    );
$$;

alter table public.student_roster enable row level security;
revoke all on public.student_roster from public, anon, authenticated;

create or replace function public.list_student_roster()
returns table (first_name text, last_name text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.is_class_teacher() then
        raise exception 'Teacher access is required to view the student roster.';
    end if;

    return query
    select roster.first_name, roster.last_name
    from public.student_roster as roster
    order by roster.last_name, roster.first_name;
end;
$$;

create or replace function public.add_student_to_roster(p_first_name text, p_last_name text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    resolved_student_id text := public.student_id_for_name(p_first_name, p_last_name);
    normalized_first text := regexp_replace(trim(p_first_name), '\s+', ' ', 'g');
    normalized_last text := regexp_replace(trim(p_last_name), '\s+', ' ', 'g');
begin
    if not public.is_class_teacher() then
        raise exception 'Teacher access is required to update the student roster.';
    end if;

    insert into public.student_roster (student_id, first_name, last_name)
    values (resolved_student_id, normalized_first, normalized_last)
    on conflict (student_id) do nothing;

    return true;
end;
$$;

create or replace function public.remove_student_from_roster(p_first_name text, p_last_name text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    resolved_student_id text := public.student_id_for_name(p_first_name, p_last_name);
    removed_student boolean;
begin
    if not public.is_class_teacher() then
        raise exception 'Teacher access is required to update the student roster.';
    end if;

    delete from public.student_roster where student_id = resolved_student_id;
    removed_student := found;
    delete from public.student_progress where student_id = resolved_student_id;
    return removed_student;
end;
$$;

create or replace function public.set_assignment_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists assignments_set_updated_at on public.assignments;
create trigger assignments_set_updated_at
before update on public.assignments
for each row execute function public.set_assignment_updated_at();

alter table public.teachers enable row level security;
alter table public.assignments enable row level security;

drop policy if exists "Teachers can read their own teacher record" on public.teachers;
create policy "Teachers can read their own teacher record"
on public.teachers for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "Students see published assignments and teachers see all" on public.assignments;
create policy "Students see published assignments and teachers see all"
on public.assignments for select to anon, authenticated
using (status = 'published' or (select public.is_class_teacher()));

drop policy if exists "Teachers can create assignments" on public.assignments;
create policy "Teachers can create assignments"
on public.assignments for insert to authenticated
with check ((select public.is_class_teacher()));

drop policy if exists "Teachers can update assignments" on public.assignments;
create policy "Teachers can update assignments"
on public.assignments for update to authenticated
using ((select public.is_class_teacher()))
with check ((select public.is_class_teacher()));

drop policy if exists "Teachers can delete assignments" on public.assignments;
create policy "Teachers can delete assignments"
on public.assignments for delete to authenticated
using ((select public.is_class_teacher()));

grant select on public.assignments to anon, authenticated;
grant insert, update, delete on public.assignments to authenticated;
grant select on public.teachers to authenticated;
grant execute on function public.is_class_teacher() to anon, authenticated;
revoke all on function public.list_student_roster() from public, anon, authenticated;
revoke all on function public.add_student_to_roster(text, text) from public, anon, authenticated;
revoke all on function public.remove_student_from_roster(text, text) from public, anon, authenticated;
grant execute on function public.list_student_roster() to authenticated;
grant execute on function public.add_student_to_roster(text, text) to authenticated;
grant execute on function public.remove_student_from_roster(text, text) to authenticated;

-- After creating your teacher account in Supabase Authentication, replace the
-- address below and run this insert to grant that account editing access.
insert into public.teachers (user_id)
select id from auth.users where email = 'teacher@example.com'
on conflict (user_id) do nothing;
