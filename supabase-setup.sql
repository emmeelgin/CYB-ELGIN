-- Run this script in the Supabase SQL Editor for the class assignments board.
-- In Supabase Authentication, create a teacher account first. Then replace the
-- example email below with that account's email and run the final INSERT.

create table if not exists public.teachers (
    user_id uuid primary key references auth.users (id) on delete cascade,
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

-- After creating your teacher account in Supabase Authentication, replace the
-- address below and run this insert to grant that account editing access.
insert into public.teachers (user_id)
select id from auth.users where email = 'teacher@example.com'
on conflict (user_id) do nothing;
