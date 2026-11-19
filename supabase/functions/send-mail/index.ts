// 업무 관리 대시보드 · 알림 메일 보내기
// pg_cron이 1분마다(보낼 메일이 있을 때만) 호출합니다. 대기열(wb_outbox)에서 2분 지난 알림을 꺼내
// 받는 사람별로 한 통에 묶어 회사 SMTP로 보냅니다.
// 배포: supabase functions deploy send-mail --no-verify-jwt  (호출은 x-cron-secret 헤더를 Vault 값과 비교해 확인)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.117.2";
// denomailer는 한글 제목·본문 인코딩이 표준과 달라(인코딩된 제목 안 공백, 소문자 16진수) 메일이 원문 그대로 보여서 nodemailer로 바꿈
import nodemailer from "npm:nodemailer@6.9.16";

type Row = { id: number; email: string; name: string; kind: string; line: string; created_at: string };

const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`환경 변수 ${k}가 없어요`);
  return v;
};

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const KIND: Record<string, string> = { task: "내 업무", comment: "댓글", leave: "휴가·투입", digest: "오늘의 마감·지연" };

const FOOT = "이 메일은 발신 전용이에요. 받을 알림 종류는 대시보드 왼쪽 메뉴 아래 '알림 설정'에서 바꿀 수 있어요.";
const when = (iso: string) => new Date(iso).toLocaleString("ko-KR", {
  timeZone: "Asia/Seoul", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", hourCycle: "h23",
});

// 알림 한 건 → 제목·내용. "…했어요: 바뀐 내용" 이면 앞은 제목, 뒤는 내용. 아침 요약은 업무 목록이 내용
function parts(r: Row) {
  if (r.kind === "digest") return { title: "오늘 마감이거나 지연된 업무가 있어요", body: r.line.split("\n") };
  const m = r.line.match(/^([\s\S]*?요): ([\s\S]*)$/);
  return m ? { title: m[1], body: [m[2]] } : { title: r.line, body: [] as string[] };
}

// 알림마다 카드 한 장: 위에 종류, 카드 안에 제목·내용·시각·바로 보기 버튼
function compose(name: string, rows: Row[], appUrl: string) {
  const onlyDigest = rows.every((r) => r.kind === "digest");
  const subject = onlyDigest ? "[업무 관리 대시보드] 오늘의 마감·지연 업무" : `[업무 관리 대시보드] 변경 알림 ${rows.length}건`;
  const text = `${name}님, 대시보드 알림이에요.\n\n` +
    rows.map((r) => { const p = parts(r); return `[${KIND[r.kind] ?? r.kind}] ${p.title}\n` + p.body.map((s) => `  ${s}\n`).join("") + `  ${when(r.created_at)}`; }).join("\n\n") +
    `\n\n대시보드 바로 보기: ${appUrl}\n${FOOT}`;
  const card = (r: Row) => {
    const p = parts(r);
    return `<div style="margin:0 0 6px;font-size:13px;font-weight:700;color:#d74844">업무 관리 대시보드 · ${esc(KIND[r.kind] ?? r.kind)}</div>
    <div style="border:1px solid #dfe3e8;border-radius:12px;padding:20px 22px;margin:0 0 24px;background:#fff">
      <div style="font-size:17px;font-weight:700;color:#141f2c;line-height:1.45">${esc(p.title)}</div>
      ${p.body.map((s) => `<div style="margin-top:8px;font-size:14px;color:#2c3a4b">${esc(s)}</div>`).join("")}
      <div style="margin-top:12px;font-size:12px;color:#8a94a0">${esc(when(r.created_at))}</div>
      <a href="${esc(appUrl)}" style="display:inline-block;margin-top:18px;padding:11px 22px;border-radius:8px;background:#d74844;color:#fff;font-size:14px;font-weight:700;text-decoration:none">대시보드 바로 보기</a>
    </div>`;
  };
  const html = `<div style="font-family:'Malgun Gothic','Apple SD Gothic Neo',sans-serif;max-width:560px;color:#141f2c;line-height:1.6">
    <p style="margin:0 0 18px;font-size:14px">${esc(name)}님, 대시보드 알림이에요.</p>
    ${rows.map(card).join("")}
    <p style="margin:0;font-size:12px;color:#8a94a0">${FOOT}</p></div>`;
  return { subject, text, html };
}

Deno.serve(async (req) => {
  const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
  const { data: ok } = await db.rpc("wb_cron_ok", { p_secret: req.headers.get("x-cron-secret") ?? "" });
  if (ok !== true) return new Response("forbidden", { status: 403 });

  // 메일 설정이 하나라도 빠졌으면 대기열에서 꺼내지 않고 그대로 둠. 설정을 채우면 다음 분에 그대로 나감
  const missing = ["SMTP_HOST", "SMTP_USER", "SMTP_PASS", "MAIL_FROM", "APP_URL"].filter((k) => !Deno.env.get(k));
  if (missing.length) return new Response(`메일 설정이 없어요: ${missing.join(", ")}`, { status: 503 });

  const { data, error } = await db.rpc("wb_take_outbox");
  if (error) return new Response(error.message, { status: 500 });
  const rows = (data ?? []) as Row[];
  if (!rows.length) return Response.json({ sent: 0 });

  const byEmail = new Map<string, Row[]>();
  for (const r of rows) byEmail.set(r.email, [...(byEmail.get(r.email) ?? []), r]);

  // Supabase Edge Functions는 25·587 포트로 나가는 연결을 막아요. 회사 SMTP의 465(SSL) 포트를 쓰세요
  const smtp = nodemailer.createTransport({
    host: env("SMTP_HOST"),
    port: Number(Deno.env.get("SMTP_PORT") ?? "465"),
    secure: true,
    auth: { user: env("SMTP_USER"), pass: env("SMTP_PASS") },
  });
  let sent = 0;
  try {
    for (const [email, list] of byEmail) {
      const ids = list.map((r) => r.id);
      try {
        const m = compose(list[0].name || "팀원", list, env("APP_URL"));
        await smtp.sendMail({ from: env("MAIL_FROM"), to: email, subject: m.subject, text: m.text, html: m.html });
        await db.rpc("wb_mark_outbox", { p_ids: ids, p_error: null });
        sent++;
      } catch (e) {
        // 실패한 묶음은 다음 분에 다시 시도해요(최대 5번)
        await db.rpc("wb_mark_outbox", { p_ids: ids, p_error: String((e as Error)?.message ?? e).slice(0, 500) });
      }
    }
  } finally {
    smtp.close();
  }
  return Response.json({ sent, recipients: byEmail.size });
});
