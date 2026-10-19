-- CampusNest shared MVP database foundation
-- Run once in the Supabase SQL Editor. Review the README before applying.
create extension if not exists pgcrypto;

-- Project owner may allowlist the first reviewer before that reviewer signs up.
create table if not exists public.admin_allowlist (
  email text primary key check (email = lower(trim(email))),
  added_at timestamptz not null default now()
);
alter table public.admin_allowlist enable row level security;
revoke all on public.admin_allowlist from anon, authenticated;

create table if not exists public.verification_requests (
  id uuid primary key default gen_random_uuid(),
  applicant_name text not null check (length(trim(applicant_name)) between 2 and 120),
  phone text not null check (length(trim(phone)) between 7 and 24),
  applicant_role text not null check (applicant_role in ('owner','agent')),
  area text not null check (area in ('Stage','Mabs','Chebarus')),
  first_property_name text not null check (length(trim(first_property_name)) between 2 and 160),
  authority_type text not null check (authority_type in ('owner','written_permission')),
  privacy_acknowledged boolean not null default false check (privacy_acknowledged = true),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  internal_review_note text,
  reviewed_by uuid references auth.users(id),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create or replace function public.submit_verification_request(
  applicant_name text,
  phone text,
  applicant_role text,
  area text,
  first_property_name text,
  authority_type text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare new_id uuid;
begin
  insert into public.verification_requests(
    applicant_name, phone, applicant_role, area, first_property_name,
    authority_type, privacy_acknowledged
  ) values (
    trim($1), trim($2), $3, $4, trim($5), $6, true
  ) returning id into new_id;
  return new_id;
end;
$$;
revoke all on function public.submit_verification_request(text,text,text,text,text,text) from public;
grant execute on function public.submit_verification_request(text,text,text,text,text,text) to anon, authenticated;
create table if not exists public.payment_intents (
  id uuid primary key default gen_random_uuid(),
  verification_request_id uuid not null references public.verification_requests(id) on delete restrict,
  amount_ksh integer not null check (amount_ksh = 200),
  status text not null default 'pending' check (status in ('pending','confirmed','failed')),
  provider text not null default 'manual',
  transaction_reference text unique,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  confirmed_by uuid references auth.users(id)
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  verification_request_id uuid not null unique references public.verification_requests(id) on delete restrict,
  full_name text not null,
  phone text not null,
  landlord_status text not null default 'approved' check (landlord_status in ('approved','suspended')),
  created_at timestamptz not null default now()
);

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  landlord_id uuid not null references public.profiles(id) on delete restrict,
  payment_intent_id uuid not null unique references public.payment_intents(id) on delete restrict,
  amount_ksh integer not null check (amount_ksh = 200),
  status text not null default 'active' check (status in ('active','expired','refunded')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists public.properties (
  id uuid primary key default gen_random_uuid(),
  landlord_id uuid not null references public.profiles(id) on delete restrict,
  name text not null check (length(trim(name)) between 2 and 160),
  area text not null check (area in ('Stage','Mabs','Chebarus')),
  property_type text not null,
  monthly_rent_ksh integer not null check (monthly_rent_ksh > 0),
  description text not null default '',
  contact_phone text not null,
  cover_photo_path text,
  moderation_status text not null default 'pending' check (moderation_status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.property_rooms (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  label text not null check (length(trim(label)) between 1 and 80),
  status text not null default 'vacant' check (status in ('vacant','occupied')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (property_id,label)
);

create unique index if not exists payment_intents_one_pending_per_request on public.payment_intents(verification_request_id) where status='pending';
create index if not exists verification_requests_status_idx on public.verification_requests(status, submitted_at desc);
create index if not exists subscriptions_landlord_expiry_idx on public.subscriptions(landlord_id, ends_at desc) where status='active';
create index if not exists properties_area_status_idx on public.properties(area, moderation_status);
create index if not exists property_rooms_property_idx on public.property_rooms(property_id);

create or replace function public.request_landlord_renewal()
returns uuid language plpgsql security definer set search_path = ''
as $$
declare request_id uuid; intent_id uuid;
begin
  select verification_request_id into request_id from public.profiles where id=auth.uid();
  if request_id is null then raise exception 'Landlord account required.'; end if;
  insert into public.payment_intents(verification_request_id,amount_ksh,status,provider)
  values (request_id,200,'pending','manual')
  on conflict (verification_request_id) where status='pending'
  do update set created_at=now()
  returning id into intent_id;
  return intent_id;
end;
$$;
revoke all on function public.request_landlord_renewal() from public;
grant execute on function public.request_landlord_renewal() to authenticated;
create or replace function public.is_campusnest_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false); $$;

create or replace function public.has_active_subscription(owner_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    join public.subscriptions s on s.landlord_id = p.id
    where p.id = owner_id and p.landlord_status = 'approved'
      and s.status = 'active' and s.ends_at > now()
  );
$$;

create or replace function public.property_is_public(property_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.properties p
    where p.id = property_id and p.moderation_status = 'approved'
      and public.has_active_subscription(p.landlord_id)
  );
$$;

-- Account signup is blocked unless a reviewer approved the request and its KSh 200 payment was confirmed.
create or replace function public.create_approved_landlord_profile()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  request_id uuid;
  request_row public.verification_requests%rowtype;
  payment_row public.payment_intents%rowtype;
begin
  if exists (select 1 from public.admin_allowlist where email=lower(new.email)) then
    update auth.users set raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb) || jsonb_build_object('role','admin') where id=new.id;
    delete from public.admin_allowlist where email=lower(new.email);
    return new;
  end if;

  begin
    request_id := (new.raw_user_meta_data ->> 'verification_request_id')::uuid;
  exception when others then
    raise exception 'An approved, paid verification request is required before account creation.';
  end;

  select * into request_row from public.verification_requests
    where id = request_id and status = 'approved';
  if not found then
    raise exception 'Landlord verification must be approved before account creation.';
  end if;

  select * into payment_row from public.payment_intents
    where verification_request_id = request_id and status = 'confirmed'
      and amount_ksh = 200 and paid_at is not null
    order by paid_at desc limit 1;
  if not found then
    raise exception 'The KSh 200 subscription payment must be confirmed before account creation.';
  end if;

  insert into public.profiles(id, verification_request_id, full_name, phone)
  values (new.id, request_row.id, request_row.applicant_name, request_row.phone);

  insert into public.subscriptions(landlord_id, payment_intent_id, amount_ksh, starts_at, ends_at)
  values (new.id, payment_row.id, 200, payment_row.paid_at, payment_row.paid_at + interval '1 month');
  return new;
end;
$$;

drop trigger if exists campusnest_require_approval_and_payment on auth.users;
create trigger campusnest_require_approval_and_payment
  after insert on auth.users for each row execute function public.create_approved_landlord_profile();

create or replace function public.protect_property_moderation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_campusnest_admin() then
    if tg_op = 'INSERT' then
      new.moderation_status := 'pending';
    elsif new.moderation_status is distinct from old.moderation_status then
      raise exception 'Only a CampusNest reviewer can change listing approval.';
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists properties_moderation_guard on public.properties;
create trigger properties_moderation_guard before insert or update on public.properties
  for each row execute function public.protect_property_moderation();

create or replace function public.touch_room_updated_at()
returns trigger language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end; $$;
drop trigger if exists property_rooms_touch on public.property_rooms;
create trigger property_rooms_touch before update on public.property_rooms
  for each row execute function public.touch_room_updated_at();

alter table public.verification_requests enable row level security;
alter table public.payment_intents enable row level security;
alter table public.profiles enable row level security;
alter table public.subscriptions enable row level security;
alter table public.properties enable row level security;
alter table public.property_rooms enable row level security;

revoke all on public.verification_requests, public.payment_intents, public.profiles, public.subscriptions, public.properties, public.property_rooms from anon, authenticated;
grant insert on public.verification_requests to anon, authenticated;
grant select, update on public.verification_requests to authenticated;
grant select, insert, update on public.payment_intents to authenticated;
grant select, insert, update, delete on public.subscriptions to authenticated;
grant select on public.profiles to authenticated;
grant update(full_name, phone) on public.profiles to authenticated;
grant select on public.properties, public.property_rooms to anon, authenticated;
grant insert, update, delete on public.properties, public.property_rooms to authenticated;

create policy verification_requests_submit on public.verification_requests
  for insert to anon, authenticated
  with check (status = 'pending' and privacy_acknowledged = true and internal_review_note is null and reviewed_by is null and reviewed_at is null);
create policy verification_requests_admin_read on public.verification_requests
  for select to authenticated using (public.is_campusnest_admin());
create policy verification_requests_admin_update on public.verification_requests
  for update to authenticated using (public.is_campusnest_admin()) with check (public.is_campusnest_admin());

create policy payment_intents_admin_all on public.payment_intents
  for all to authenticated using (public.is_campusnest_admin()) with check (public.is_campusnest_admin() and exists (select 1 from public.verification_requests r where r.id=verification_request_id and r.status='approved'));
create policy payment_intents_owner_read on public.payment_intents
  for select to authenticated using (exists (
    select 1 from public.profiles p where p.id=auth.uid()
      and p.verification_request_id=payment_intents.verification_request_id
  ));

create policy profiles_owner_read on public.profiles
  for select to authenticated using (id=auth.uid() or public.is_campusnest_admin());
create policy profiles_owner_update on public.profiles
  for update to authenticated using (id=auth.uid()) with check (id=auth.uid());

create policy subscriptions_owner_read on public.subscriptions
  for select to authenticated using (landlord_id=auth.uid() or public.is_campusnest_admin());
create policy subscriptions_admin_manage on public.subscriptions
  for all to authenticated using (public.is_campusnest_admin()) with check (public.is_campusnest_admin());

create policy properties_public_read on public.properties
  for select to anon, authenticated using (moderation_status='approved' and public.has_active_subscription(landlord_id));
create policy properties_owner_read on public.properties
  for select to authenticated using (landlord_id=auth.uid());
create policy properties_owner_insert on public.properties
  for insert to authenticated with check (landlord_id=auth.uid() and public.has_active_subscription(auth.uid()));
create policy properties_owner_update on public.properties
  for update to authenticated using (landlord_id=auth.uid() and public.has_active_subscription(auth.uid()))
  with check (landlord_id=auth.uid() and public.has_active_subscription(auth.uid()));
create policy properties_owner_delete on public.properties
  for delete to authenticated using (landlord_id=auth.uid() and public.has_active_subscription(auth.uid()));
create policy properties_admin_all on public.properties
  for all to authenticated using (public.is_campusnest_admin()) with check (public.is_campusnest_admin());

create policy rooms_public_read on public.property_rooms
  for select to anon, authenticated using (public.property_is_public(property_id));
create policy rooms_owner_read on public.property_rooms
  for select to authenticated using (exists (
    select 1 from public.properties p where p.id=property_id and p.landlord_id=auth.uid()
  ));
create policy rooms_owner_insert on public.property_rooms
  for insert to authenticated with check (exists (
    select 1 from public.properties p where p.id=property_id and p.landlord_id=auth.uid()
  ) and public.has_active_subscription(auth.uid()));
create policy rooms_owner_update on public.property_rooms
  for update to authenticated using (exists (
    select 1 from public.properties p where p.id=property_id and p.landlord_id=auth.uid()
  ) and public.has_active_subscription(auth.uid())) with check (exists (
    select 1 from public.properties p where p.id=property_id and p.landlord_id=auth.uid()
  ) and public.has_active_subscription(auth.uid()));
create policy rooms_owner_delete on public.property_rooms
  for delete to authenticated using (exists (
    select 1 from public.properties p where p.id=property_id and p.landlord_id=auth.uid()
  ) and public.has_active_subscription(auth.uid()));
create policy rooms_admin_all on public.property_rooms
  for all to authenticated using (public.is_campusnest_admin()) with check (public.is_campusnest_admin());

-- Public bucket is only for ordinary rental photos. Never upload IDs, deeds, or private verification documents.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('property-photos','property-photos',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
create policy property_photo_upload_own on storage.objects for insert to authenticated
  with check (bucket_id='property-photos' and (storage.foldername(name))[1]=auth.uid()::text and public.has_active_subscription(auth.uid()));
create policy property_photo_update_own on storage.objects for update to authenticated
  using (bucket_id='property-photos' and (storage.foldername(name))[1]=auth.uid()::text and public.has_active_subscription(auth.uid()))
  with check (bucket_id='property-photos' and (storage.foldername(name))[1]=auth.uid()::text and public.has_active_subscription(auth.uid()));
create policy property_photo_delete_own on storage.objects for delete to authenticated
  using (bucket_id='property-photos' and (storage.foldername(name))[1]=auth.uid()::text and public.has_active_subscription(auth.uid()));
