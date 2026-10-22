// 업무 관리 대시보드 · 알림 메일 보내기
// pg_cron이 1분마다(보낼 메일이 있을 때만) 호출합니다. 대기열(wb_outbox)에서 2분 지난 알림을 꺼내
// 받는 사람별로 한 통에 묶어 회사 SMTP로 보냅니다.
// 배포: supabase functions deploy send-mail --no-verify-jwt  (호출은 x-cron-secret 헤더를 Vault 값과 비교해 확인)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.117.2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

type Row = { id: number; email: string; name: string; kind: string; line: string; created_at: string };

const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`환경 변수 ${k}가 없어요`);
  return v;
};

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const KIND: Record<string, string> = { task: "내 업무", comment: "댓글", leave: "휴가·투입", digest: "오늘의 마감·지연" };

function compose(name: string, rows: Row[], appUrl: string) {
  const onlyDigest = rows.every((r) => r.kind === "digest");
  const subject = onlyDigest ? "[업무 관리 대시보드] 오늘의 마감·지연 업무" : `[업무 관리 대시보드] 변경 알림 ${rows.length}건`;
  const groups = Object.keys(KIND).map((k) => [k, rows.filter((r) => r.kind === k)] as const).filter(([, l]) => l.length);
  const lines = (r: Row) => r.line.split("\n");
  const text = `${name}님, 대시보드 알림이에요.\n\n` +
    groups.map(([k, l]) => `■ ${KIND[k]}\n` + l.flatMap(lines).map((s) => `- ${s}`).join("\n")).join("\n\n") +
    `\n\n대시보드 열기: ${appUrl}\n알림은 대시보드의 '내 프로필'에서 끌 수 있어요.`;
  const html = `<div style="font-family:'Malgun Gothic',sans-serif;font-size:14px;color:#141f2c;line-height:1.6">
    <p>${esc(name)}님, 대시보드 알림이에요.</p>
    ${groups.map(([k, l]) => `<p style="margin:16px 0 4px;font-weight:700">${KIND[k]}</p><ul style="margin:0;padding-left:20px">${
      l.flatMap(lines).map((s) => `<li>${esc(s)}</li>`).join("")}</ul>`).join("")}
    <p style="margin-top:20px"><a href="${esc(appUrl)}" style="color:#d74844;font-weight:700">대시보드 열기</a></p>
    <p style="color:#4b5765;font-size:12px">알림은 대시보드의 '내 프로필'에서 끌 수 있어요.</p></div>`;
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
  const smtp = new SMTPClient({
    connection: {
      hostname: env("SMTP_HOST"),
      port: Number(Deno.env.get("SMTP_PORT") ?? "465"),
      tls: true,
      auth: { username: env("SMTP_USER"), password: env("SMTP_PASS") },
    },
  });
  let sent = 0;
  try {
    for (const [email, list] of byEmail) {
      const ids = list.map((r) => r.id);
      try {
        const m = compose(list[0].name || "팀원", list, env("APP_URL"));
        await smtp.send({ from: env("MAIL_FROM"), to: email, subject: m.subject, content: m.text, html: m.html });
        await db.rpc("wb_mark_outbox", { p_ids: ids, p_error: null });
        sent++;
      } catch (e) {
        // 실패한 묶음은 다음 분에 다시 시도해요(최대 5번)
        await db.rpc("wb_mark_outbox", { p_ids: ids, p_error: String((e as Error)?.message ?? e).slice(0, 500) });
      }
    }
  } finally {
    await smtp.close();
  }
  return Response.json({ sent, recipients: byEmail.size });
});
