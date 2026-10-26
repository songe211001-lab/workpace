# 업무 관리 대시보드 · 서버 버전

Claude 아티팩트로 만들던 대시보드를 **GitHub Pages + Supabase**로 옮긴 버전이에요. 회사 메일로 로그인하고, 처음 들어온 사람이 본인 프로필을 직접 등록하며, 내 업무·휴가가 바뀌면 메일로 알려 줘요.

## 파일

| 파일 | 무엇 |
|---|---|
| `index.html` | 화면 전체(단일 파일). 맨 앞 `<script>`의 `SUPABASE_URL`, `SUPABASE_ANON_KEY`만 채우면 돼요 |
| `supabase/schema.sql` | 테이블·권한(RLS)·알림 대기열·예약 작업. SQL Editor에 통째로 붙여 실행 |
| `supabase/functions/send-mail/index.ts` | 알림 메일을 회사 SMTP로 보내는 Edge Function |
| `workboard.html` | 예전 아티팩트 버전(참고용). 더는 고치지 않아요 |

## 구조

- **데이터**: 표 하나(`wb_docs`)에 업무·프로젝트·구성원·휴가 등 모든 컬렉션을 `coll` + `id` + `data(jsonb)`로 저장해요. 화면 코드는 아티팩트 때의 `db.collection('tasks').doc(id)` 호출을 그대로 쓰고, `index.html` 앞부분의 연결 코드가 이 호출을 Supabase로 바꿔 줘요.
- **수정 저장**: 바뀐 필드만 `wb_patch`로 합쳐 저장해요(객체 안쪽까지). 두 사람이 같은 업무의 다른 칸을 고쳐도 둘 다 남아요.
- **실시간**: Supabase Realtime으로 다른 사람 변경이 바로 들어와요. 끊기면 1분마다 새로 받아 와요.
- **로그인**: 회사 메일과 비밀번호로 들어가요. 로그인 화면에서 '로그인' / '회원가입' 탭을 골라요.
  - **회원가입**: 이름·회사 메일·비밀번호(8자 이상)를 넣으면 메일로 6자리 확인 코드가 와요. 코드를 넣으면 가입이 끝나요. 이미 가입된 메일이면 로그인 탭으로 안내해요.
  - **비밀번호 찾기 · 처음 만들기**: 메일로 받은 코드를 넣고 새 비밀번호를 만들어요. 예전에 코드로만 로그인하던 사람도 여기서 비밀번호를 한 번 만들면 돼요.
  - 처음 들어오면 파트·소속 프로젝트를 고르는 마무리 화면이 나와요. 관리자가 구성원에 그 메일을 미리 적어 두었으면 마무리 화면 없이 바로 연결돼요.
  - **로그아웃**: 화면 위 "내 프로필" 옆 버튼. 로그인 정보는 탭에만 남아서 창(탭)을 닫으면 로그아웃돼요.
  - 가입 확인·비밀번호 찾기 코드는 링크 대신 숫자로 받아요. 회사 메일 보안 검사가 링크를 미리 열어 무효가 되는 경우가 있어서예요.
- **알림**: 업무·댓글·휴가·투입 문서가 바뀌면 DB 트리거가 받는 사람을 골라 `wb_outbox`에 한 줄씩 넣어요. 1분마다 `send-mail` 함수가 2분 지난 것을 꺼내, 받는 사람별로 한 통에 묶어 보내요. 실패하면 다음 분에 다시 시도해요(최대 5번).

## 권한

| 대상 | 직원(회사 메일 로그인) | 관리자 |
|---|---|---|
| 업무·휴가·투입·주간 보고·작업 시간·템플릿 | 읽기·쓰기 | 읽기·쓰기 |
| 내 프로필(구성원) | 본인 것, 아직 아무도 연결 안 한 것만 | 전부 |
| 댓글 | 쓰기, 본인 댓글만 삭제 | 전부 |
| 프로젝트·파트·사이트 제목·RMS 주소 규칙 | 읽기만 | 읽기·쓰기 |
| 변경 이력 | 추가·읽기 | 추가·읽기 |

회사 메일이 아닌 계정은 가입이 막히고(Before User Created 훅), 가입되더라도 RLS가 아무것도 보여 주지 않아요. 관리자가 아니면 화면에서 프로젝트 관리·파트 관리·구성원 관리 버튼이 숨겨져요.

## 알림 메일

| 종류 | 받는 사람 | 언제 |
|---|---|---|
| 내 업무 변동 | 담당자 | 담당자로 지정됨, 담당에서 빠짐, 진행 현황·완료 일정·우선순위·요청내용 변경, 삭제 |
| 내 업무 댓글 | 담당자 + 요청자(구성원 이름이 같을 때) | 댓글이 달렸을 때 |
| 아침 요약 | 담당자 | 평일 08:30, 오늘·내일 마감과 지연된 내 업무가 있을 때만 |
| 내 휴가·투입 변동 | 그 휴가·투입의 구성원 | 다른 사람이 등록·수정·삭제했을 때 |

- 내가 한 변경은 나에게 보내지 않아요.
- 각자 화면 오른쪽 위 **내 프로필**에서 종류별로 끌 수 있어요.
- 계정과 연결되지 않은 구성원(아직 로그인하지 않은 사람)에게는 보내지 않아요.

## 설정 순서

### 1. Supabase 프로젝트
1. supabase.com에서 새 프로젝트를 만들어요(Region: Northeast Asia (Seoul) 추천).
2. SQL Editor에 `supabase/schema.sql`을 통째로 붙여 Run 해요. 여러 번 실행해도 돼요.
   - 로그인할 수 있는 도메인은 지금 `medialog.co.kr`(본사)과 `medialogpartners.co.kr`(협력사)이에요. 바꾸거나 더하려면 schema.sql 두 곳(`wb_is_staff`, `wb_before_user_created`)과 `index.html`의 `STAFF_DOMAINS`를 함께 바꿔요.
3. 예약 작업이 쓸 값 두 개를 Vault에 넣어요(SQL Editor).
   ```sql
   select vault.create_secret('https://<프로젝트 ref>.supabase.co', 'wb_project_url');
   select vault.create_secret('<길고 랜덤한 문자열>', 'wb_cron_secret');
   ```

### 2. 로그인 메일 (Authentication)
1. **SMTP**: Authentication > Emails > SMTP Settings에서 회사 SMTP를 넣어요(호스트·포트·계정·비밀번호·보내는 주소). Supabase 기본 메일은 시간당 몇 통뿐이라 실제로는 못 써요.
2. **로그인 설정**: Authentication > Sign In / Providers의 **Email** 항목을 켜 두고(비밀번호 로그인), Confirm email을 켜고, Email OTP length를 `6`으로 맞춰요. 비밀번호 최소 길이는 8 이상을 권해요.
3. **메일 내용**: Authentication > Emails > Templates에서 **Confirm sign up**(가입 확인)과 **Reset Password**(비밀번호 찾기) 두 메일 본문에 코드가 보이게 `{{ .Token }}`을 넣어요. 링크(`{{ .ConfirmationURL }}`)만 있으면 화면에 넣을 숫자가 오지 않아요.
   ```html
   <h2>업무 관리 대시보드 확인 코드</h2>
   <p>아래 코드를 화면에 넣어 주세요. 1시간 동안 쓸 수 있어요.</p>
   <p style="font-size:24px;font-weight:700;letter-spacing:4px">{{ .Token }}</p>
   ```
4. **URL**: Authentication > URL Configuration의 Site URL에 GitHub Pages 주소를 넣어요.
5. **가입 제한**: Authentication > Hooks > Before User Created에 Postgres 함수 `public.wb_before_user_created`를 연결해요.
6. **보내는 횟수**: Authentication > Rate Limits에서 시간당 메일 수를 팀 규모에 맞게 올려요(예: 100).

### 3. 알림 메일 함수 (Edge Function)
Supabase CLI를 쓰는 경우:
```bash
supabase login
```
```bash
supabase link --project-ref <프로젝트 ref>
```
```bash
supabase secrets set SMTP_HOST=<회사 SMTP 주소> SMTP_PORT=465 SMTP_USER=<계정> SMTP_PASS=<비밀번호> MAIL_FROM="업무 대시보드 <보내는주소@medialog.co.kr>" APP_URL=<GitHub Pages 주소> CRON_SECRET=<Vault에 넣은 wb_cron_secret과 같은 값>
```
```bash
supabase functions deploy send-mail --no-verify-jwt
```
CLI가 없으면 대시보드 Edge Functions에서 `send-mail`을 새로 만들어 `index.ts` 내용을 붙여 넣고, Secrets에 같은 값을 넣고, "Verify JWT"를 꺼요.

> **포트 주의**: Supabase Edge Function은 25·587 포트로 나가는 연결을 막아요. 회사 SMTP의 **465(SSL)** 포트를 써야 해요. IT팀에 465 포트 사용과 발송 계정을 요청하세요. 로그인 메일(2번)은 Supabase Auth가 보내므로 587도 돼요.

### 4. 화면 배포 (GitHub Pages)
1. `index.html` 맨 앞 연결 코드의 `SUPABASE_URL`, `SUPABASE_ANON_KEY`(Settings > API의 anon public)를 채워요. **service_role 키는 절대 넣지 마세요.**
2. GitHub 저장소에 올리고 Settings > Pages에서 배포해요.

### 5. 첫 관리자
본인이 먼저 로그인해서 프로필을 등록한 뒤, SQL Editor에서:
```sql
insert into public.wb_admins (user_id)
select id from auth.users where email = '<관리자 메일>@medialog.co.kr'
on conflict do nothing;
```
관리자를 빼려면 `delete from public.wb_admins where user_id = (select id from auth.users where email = '...');`

## 배포 후 확인
1. 회원가입(메일 코드 확인) → 로그인, 비밀번호 찾기가 되는지, 다른 도메인 메일은 막히는지
2. 처음 로그인하면 프로필 등록 화면이 나오는지
3. 두 브라우저(두 계정)에서 한쪽이 업무를 바꾸면 다른 쪽에 바로 보이는지
4. A가 B를 담당자로 업무를 만들고 2~3분 뒤 B에게 메일이 오는지. 안 오면 SQL Editor에서:
   ```sql
   select id, email, kind, attempts, error, sent_at from public.wb_outbox order by id desc limit 20;
   ```
   `error`에 SMTP 오류가 보이면 3번 설정을, 줄 자체가 없으면 받는 사람의 프로필 연결·알림 설정을 확인해요.

## 위험·한계
1. **SMTP 연결은 실제 회사 서버로 확인하지 못했어요.** 465 포트·TLS 방식이 회사 서버와 맞는지 배포 후 4번으로 먼저 확인하세요.
2. **schema.sql은 실제 Supabase에서 아직 실행해 보지 않았어요.** 오류가 나면 메시지를 그대로 알려 주세요.
3. 컬렉션을 통째로 받아 두는 방식이라, 업무가 수만 건이 되면 기간별로 나눠 받도록 바꿔야 해요(`index.html`의 `ponytail:` 주석).
4. 무료 프로젝트는 한동안 쓰지 않으면 일시 정지될 수 있어요(대시보드에서 다시 켜면 돼요).
5. 원본 아티팩트의 데이터는 아직 옮기지 않았어요. 원본 링크가 있으면 `wb_docs`로 옮길 수 있어요.
