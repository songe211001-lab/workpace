-- ════════════════════════════════════════════════════════════
-- 업무 관리 워크보드 · Supabase 스키마 (회사 메일 로그인 + 변경 알림 메일)
-- 대시보드 > SQL Editor에 통째로 붙여넣고 Run 하세요. 여러 번 실행해도 됩니다.
-- 회사 메일 도메인은 아래 'medialog.co.kr' 두 곳(wb_is_staff, wb_before_user_created)과 index.html의 STAFF_DOMAIN을 함께 바꾸세요.
-- ════════════════════════════════════════════════════════════

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1. 문서 테이블 하나에 모든 컬렉션을 담음 (화면 코드의 db.collection('tasks').doc(id) 구조 그대로)
--    coll: tasks, projects, parts, members, leaves, assignments, reports, history, worklogs, comments, templates, settings
create table if not exists public.wb_docs (
  coll        text not null,
  id          text not null,
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid(),
  primary key (coll, id)
);
create index if not exists wb_docs_member_uid_idx on public.wb_docs ((data->>'userId')) where coll = 'members';
create index if not exists wb_docs_task_due_idx on public.wb_docs ((data->>'dueDate')) where coll = 'tasks';

-- 관리자 목록. 대시보드 SQL로만 넣고 뺍니다 (README 참고)
create table if not exists public.wb_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- 보낼 알림 메일 대기열. 화면에서는 읽을 수 없고, send-mail 함수만 꺼내 씀
create table if not exists public.wb_outbox (
  id          bigint generated always as identity primary key,
  email       text not null,
  name        text not null default '',
  kind        text not null,            -- task · comment · leave · digest
  line        text not null,
  created_at  timestamptz not null default now(),
  taken_at    timestamptz,
  sent_at     timestamptz,
  attempts    integer not null default 0,
  error       text
);
create index if not exists wb_outbox_pending_idx on public.wb_outbox (created_at) where sent_at is null;

-- updated_at·updated_by는 항상 서버가 채움
create or replace function public.wb_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
drop trigger if exists wb_docs_touch on public.wb_docs;
create trigger wb_docs_touch before insert or update on public.wb_docs
  for each row execute function public.wb_touch();

-- 2. 권한 판단
-- 회사 메일로 로그인한 사람만 '직원'
create or replace function public.wb_is_staff()
returns boolean language sql stable as $$
  select coalesce(lower(auth.jwt()->>'email'), '') like '%@medialog.co.kr';
$$;

create or replace function public.wb_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.wb_admins where user_id = auth.uid());
$$;

-- 컬렉션별 쓰기 규칙: 프로젝트·파트·사이트 설정은 관리자만, 구성원(프로필)은 본인 것과 아직 아무도 연결 안 한 것만,
-- 댓글은 쓴 사람만, 변경 이력은 추가만. 나머지(업무·휴가·투입·보고·작업 시간·템플릿)는 직원 누구나
create or replace function public.wb_can_write(p_coll text, p_data jsonb)
returns boolean language sql stable as $$
  select public.wb_is_staff() and (public.wb_is_admin() or case
    when p_coll in ('projects', 'parts', 'settings') then false
    when p_coll = 'members'  then coalesce(p_data->>'userId', '') in ('', auth.uid()::text)
    when p_coll = 'comments' then p_data->>'by' = auth.uid()::text
    when p_coll = 'history'  then false
    else true end);
$$;

alter table public.wb_docs   enable row level security;
alter table public.wb_admins enable row level security;
alter table public.wb_outbox enable row level security;

drop policy if exists wb_docs_select on public.wb_docs;
create policy wb_docs_select on public.wb_docs for select to authenticated using (public.wb_is_staff());
drop policy if exists wb_docs_insert on public.wb_docs;
create policy wb_docs_insert on public.wb_docs for insert to authenticated
  with check (public.wb_can_write(coll, data) or (coll = 'history' and public.wb_is_staff()));
drop policy if exists wb_docs_update on public.wb_docs;
create policy wb_docs_update on public.wb_docs for update to authenticated
  using (public.wb_can_write(coll, data)) with check (public.wb_can_write(coll, data));
drop policy if exists wb_docs_delete on public.wb_docs;
create policy wb_docs_delete on public.wb_docs for delete to authenticated using (public.wb_can_write(coll, data));

revoke all on public.wb_docs, public.wb_admins, public.wb_outbox from anon, authenticated;
grant select, insert, update, delete on public.wb_docs to authenticated;

-- 3. 바뀐 필드만 합쳐 저장 (객체 안쪽까지 합침). 두 사람이 같은 문서의 다른 칸을 고쳐도 둘 다 남아요
create or replace function public.wb_jsonb_merge(a jsonb, b jsonb)
returns jsonb language plpgsql immutable as $$
declare k text; v jsonb; r jsonb;
begin
  if jsonb_typeof(a) is distinct from 'object' or jsonb_typeof(b) is distinct from 'object' then return b; end if;
  r := a;
  for k, v in select * from jsonb_each(b) loop
    if jsonb_typeof(r->k) = 'object' and jsonb_typeof(v) = 'object' then
      r := jsonb_set(r, array[k], public.wb_jsonb_merge(r->k, v));
    else
      r := jsonb_set(r, array[k], v);
    end if;
  end loop;
  return r;
end $$;

-- 권한은 호출한 사람 기준(RLS 그대로). 문서가 없거나 고칠 수 없으면 오류
create or replace function public.wb_patch(p_coll text, p_id text, p_patch jsonb)
returns void language plpgsql security invoker set search_path = public as $$
begin
  update public.wb_docs set data = public.wb_jsonb_merge(data, p_patch) where coll = p_coll and id = p_id;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
end $$;

grant execute on function public.wb_patch(text, text, jsonb), public.wb_is_admin() to authenticated;

-- 4. 알림 메일 대기열에 넣기
create or replace function public.wb_md(p text)
returns text language sql immutable as $$
  select case when coalesce(p, '') ~ '^\d{4}-\d{2}-\d{2}' then ltrim(substr(p, 6, 2), '0') || '/' || ltrim(substr(p, 9, 2), '0') else '없음' end;
$$;
create or replace function public.wb_status(p text)
returns text language sql immutable as $$
  select case p when 'wait' then '대기' when 'doing' then '진행중' when 'review' then '검토중' when 'hold' then '보류' when 'done' then '완료' else coalesce(p, '없음') end;
$$;
create or replace function public.wb_pri(p text)
returns text language sql immutable as $$
  select case p when '0' then '긴급' when '1' then '높음' when '2' then '보통' when '3' then '낮음' else '보통' end;
$$;
create or replace function public.wb_leave_label(p text)
returns text language sql immutable as $$
  select case p when 'annual' then '연차' when 'am' then '오전 반차' when 'pm' then '오후 반차' when 'qam' then '오전 반반차'
    when 'qpm' then '오후 반반차' when 'quarter' then '반반차' when 'sick' then '병가' when 'family' then '경조사' else '공가·기타' end;
$$;

-- 구성원 한 명에게 알림 한 줄. 본인이 한 변경, 계정 연결 전, 알림을 끈 종류는 보내지 않음
create or replace function public.wb_queue(p_member text, p_kind text, p_line text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare m jsonb; v_uid text; v_email text;
begin
  if coalesce(p_member, '') = '' then return; end if;
  select data into m from public.wb_docs where coll = 'members' and id = p_member;
  if m is null then return; end if;
  v_uid := coalesce(m->>'userId', '');
  if v_uid = '' or v_uid = coalesce(auth.uid()::text, '') then return; end if;
  if coalesce(m->'notify'->>p_kind, 'true') = 'false' then return; end if;
  select email into v_email from auth.users where id::text = v_uid;
  if v_email is null then return; end if;
  insert into public.wb_outbox (email, name, kind, line) values (v_email, coalesce(m->>'name', ''), p_kind, p_line);
end $$;

-- 업무·댓글·휴가·투입 문서가 바뀌면 알림을 만듦
create or replace function public.wb_enqueue()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_coll text; o jsonb; n jsonb; r jsonb; t jsonb;
  v_actor text; v_head text; v_chg text; v_line text; v_req text; v_verb text;
begin
  if tg_op = 'DELETE' then v_coll := old.coll; o := old.data;
  else v_coll := new.coll; n := new.data; if tg_op = 'UPDATE' then o := old.data; end if; end if;
  if v_coll not in ('tasks', 'comments', 'leaves', 'assignments') then return null; end if;

  select coalesce(nullif(data->>'name', ''), '누군가') into v_actor
    from public.wb_docs where coll = 'members' and data->>'userId' = auth.uid()::text limit 1;
  v_actor := coalesce(v_actor, '누군가');
  v_verb := case tg_op when 'INSERT' then '등록' when 'UPDATE' then '수정' else '삭제' end;

  if v_coll = 'tasks' then
    r := coalesce(n, o);
    select '"' || (r->>'title') || '"' || coalesce(' (' || (p.data->>'name') || ')', '') into v_head
      from (select 1) x left join public.wb_docs p on p.coll = 'projects' and p.id = r->>'projectId';
    if tg_op = 'INSERT' then
      perform public.wb_queue(n->>'assigneeId', 'task', v_actor || '님이 ' || v_head || ' 업무를 배정했어요 · 완료 일정 ' || public.wb_md(n->>'dueDate'));
    elsif tg_op = 'DELETE' then
      perform public.wb_queue(o->>'assigneeId', 'task', v_actor || '님이 ' || v_head || ' 업무를 삭제했어요');
    elsif coalesce(n->>'assigneeId', '') <> coalesce(o->>'assigneeId', '') then
      perform public.wb_queue(n->>'assigneeId', 'task', v_actor || '님이 ' || v_head || ' 업무를 배정했어요 · 완료 일정 ' || public.wb_md(n->>'dueDate'));
      perform public.wb_queue(o->>'assigneeId', 'task', v_actor || '님이 ' || v_head || ' 업무의 담당자를 다른 사람으로 바꿨어요');
    else
      v_chg := concat_ws(', ',
        case when (n->>'status') is distinct from (o->>'status') then '진행 현황 ' || public.wb_status(o->>'status') || ' → ' || public.wb_status(n->>'status') end,
        case when coalesce(n->>'dueDate', '') <> coalesce(o->>'dueDate', '') then '완료 일정 ' || public.wb_md(o->>'dueDate') || ' → ' || public.wb_md(n->>'dueDate') end,
        case when (n->>'priority') is distinct from (o->>'priority') then '우선순위 ' || public.wb_pri(o->>'priority') || ' → ' || public.wb_pri(n->>'priority') end,
        case when coalesce(n->>'title', '') <> coalesce(o->>'title', '') then '요청내용 변경' end);
      if v_chg <> '' then
        perform public.wb_queue(n->>'assigneeId', 'task', v_actor || '님이 ' || v_head || ' 업무를 바꿨어요: ' || v_chg);
      end if;
    end if;

  elsif v_coll = 'comments' and tg_op = 'INSERT' then
    select data into t from public.wb_docs where coll = 'tasks' and id = n->>'taskId';
    if t is null then return null; end if;
    v_line := v_actor || '님이 "' || (t->>'title') || '"에 댓글을 남겼어요: ' || left(n->>'text', 120);
    perform public.wb_queue(t->>'assigneeId', 'comment', v_line);
    select id into v_req from public.wb_docs where coll = 'members' and data->>'name' = t->>'requester' limit 1;
    if v_req is distinct from (t->>'assigneeId') then perform public.wb_queue(v_req, 'comment', v_line); end if;

  elsif v_coll = 'leaves' then
    r := coalesce(n, o);
    v_line := v_actor || '님이 내 휴가를 ' || v_verb || '했어요: ' || public.wb_leave_label(r->>'type') || ' ' || public.wb_md(r->>'date')
      || case when coalesce(r->>'endDate', '') not in ('', coalesce(r->>'date', '')) then '~' || public.wb_md(r->>'endDate') else '' end;
    perform public.wb_queue(r->>'memberId', 'leave', v_line);
    if tg_op = 'UPDATE' and (o->>'memberId') is distinct from (n->>'memberId') then
      perform public.wb_queue(o->>'memberId', 'leave', v_actor || '님이 내 휴가 기록을 다른 사람 것으로 옮겼어요');
    end if;

  elsif v_coll = 'assignments' then
    r := coalesce(n, o);
    select v_actor || '님이 내 투입 기록을 ' || v_verb || '했어요: ' || coalesce(p.data->>'name', '프로젝트') || ' '
           || public.wb_md(r->>'start') || '~' || case when coalesce(r->>'end', '') = '' then '계속' else public.wb_md(r->>'end') end
           || ' · ' || coalesce(r->>'rate', '100') || '%'
      into v_line from (select 1) x left join public.wb_docs p on p.coll = 'projects' and p.id = r->>'projectId';
    perform public.wb_queue(r->>'memberId', 'leave', v_line);
  end if;
  return null;
end $$;

drop trigger if exists wb_docs_notify on public.wb_docs;
create trigger wb_docs_notify after insert or update or delete on public.wb_docs
  for each row execute function public.wb_enqueue();

-- 평일 아침 요약: 오늘·내일 마감과 지연된 내 업무
create or replace function public.wb_queue_digest()
returns void language plpgsql security definer set search_path = public, auth as $$
declare mm record; v_today date := (now() at time zone 'Asia/Seoul')::date; v_lines text; v_email text;
begin
  for mm in select id, data from public.wb_docs
             where coll = 'members' and coalesce(data->>'userId', '') <> '' and coalesce(data->'notify'->>'digest', 'true') <> 'false' loop
    select string_agg(
             case when (t.data->>'dueDate')::date < v_today then '[지연 ' || (v_today - (t.data->>'dueDate')::date) || '일] '
                  when (t.data->>'dueDate')::date = v_today then '[오늘 마감] ' else '[내일 마감] ' end
             || (t.data->>'title') || coalesce(' (' || (p.data->>'name') || ')', ''),
             E'\n' order by t.data->>'dueDate')
      into v_lines
      from public.wb_docs t left join public.wb_docs p on p.coll = 'projects' and p.id = t.data->>'projectId'
     where t.coll = 'tasks' and coalesce(t.data->>'status', '') not in ('done', 'hold')
       and coalesce(t.data->>'dueDate', '') ~ '^\d{4}-\d{2}-\d{2}$' and (t.data->>'dueDate')::date <= v_today + 1
       and (t.data->>'assigneeId' = mm.id or (coalesce(t.data->>'assigneeId', '') = '' and t.data->>'assignee' = mm.data->>'name'));
    if v_lines is null then continue; end if;
    select email into v_email from auth.users where id::text = mm.data->>'userId';
    if v_email is null then continue; end if;
    insert into public.wb_outbox (email, name, kind, line, created_at)
      values (v_email, coalesce(mm.data->>'name', ''), 'digest', v_lines, now() - interval '5 minutes');
  end loop;
end $$;

-- send-mail 함수가 쓰는 꺼내기·완료 표시. 변경이 몰릴 때 한 통으로 묶이도록 2분 지난 것만 꺼냄
create or replace function public.wb_take_outbox()
returns setof public.wb_outbox language sql security definer set search_path = public as $$
  update public.wb_outbox set taken_at = now(), attempts = attempts + 1
   where id in (select id from public.wb_outbox
                 where sent_at is null and attempts < 5 and created_at < now() - interval '2 minutes'
                   and (taken_at is null or taken_at < now() - interval '10 minutes')
                 order by id limit 500 for update skip locked)
  returning *;
$$;
create or replace function public.wb_mark_outbox(p_ids bigint[], p_error text default null)
returns void language sql security definer set search_path = public as $$
  update public.wb_outbox
     set sent_at = case when p_error is null then now() end, error = p_error, taken_at = null
   where id = any(p_ids);
$$;

-- send-mail 함수가 호출한 쪽의 비밀 문자열(x-cron-secret)을 Vault 값과 비교. 함수 설정에 비밀값을 따로 넣지 않아도 됨
create or replace function public.wb_cron_ok(p_secret text)
returns boolean language sql stable security definer set search_path = public, vault as $$
  select exists (select 1 from vault.decrypted_secrets where name = 'wb_cron_secret' and decrypted_secret = p_secret);
$$;
revoke execute on function public.wb_cron_ok(text) from public, anon, authenticated;
grant execute on function public.wb_cron_ok(text) to service_role;

revoke execute on function public.wb_queue(text, text, text), public.wb_queue_digest(), public.wb_take_outbox(),
  public.wb_mark_outbox(bigint[], text) from public, anon, authenticated;
grant execute on function public.wb_take_outbox(), public.wb_mark_outbox(bigint[], text) to service_role;

-- 5. 회사 메일이 아니면 가입 자체를 막음 (Authentication > Hooks > Before User Created 에 이 함수를 연결)
create or replace function public.wb_before_user_created(event jsonb)
returns jsonb language plpgsql as $$
begin
  if lower(coalesce(event->'user'->>'email', '')) like '%@medialog.co.kr' then return '{}'::jsonb; end if;
  return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', '회사 메일로만 가입할 수 있어요.'));
end $$;
revoke execute on function public.wb_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.wb_before_user_created(jsonb) to supabase_auth_admin;

-- 6. Realtime: 다른 사람 변경을 바로 받음
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'wb_docs') then
    alter publication supabase_realtime add table public.wb_docs;
  end if;
end $$;

-- 7. 예약 작업 (Vault에 wb_project_url, wb_cron_secret을 먼저 넣으세요. README 참고)
select cron.unschedule(jobname) from cron.job where jobname in ('wb-send-mail', 'wb-digest', 'wb-cleanup');
-- 1분마다: 보낼 메일이 있을 때만 send-mail 함수 호출
select cron.schedule('wb-send-mail', '* * * * *', $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'wb_project_url') || '/functions/v1/send-mail',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'wb_cron_secret')),
    body := '{}'::jsonb)
  where exists (select 1 from public.wb_outbox where sent_at is null and attempts < 5);
$job$);
-- 평일 08:30 (한국 시간) 아침 요약
select cron.schedule('wb-digest', '30 23 * * 0-4', $job$ select public.wb_queue_digest(); $job$);
-- 매일 03:00 (한국 시간): 180일 지난 변경 이력, 30일 지난 메일 기록 정리
select cron.schedule('wb-cleanup', '0 18 * * *', $job$
  delete from public.wb_docs where coll = 'history' and data->>'at' < to_char(now() - interval '180 days', 'YYYY-MM-DD');
  delete from public.wb_outbox where created_at < now() - interval '30 days';
$job$);
