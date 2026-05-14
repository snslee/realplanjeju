// ============================================================
// Edge Function: agent-evaluate
// ============================================================
// 작성: 2026-05-14 / 44차 회기 / v1.0
// 출처: 23_에이전트시스템_v1.0.md + 24_에이전트_카탈로그.md (rp_agent_eval_v1)
// LLM: Claude Haiku 4.5 (비용 1/10 / 채점 전용)
// 트리거: POST /functions/v1/agent-evaluate
// 정합: §6 데이터 주권 (Supabase 단일) / §9 과잉 X / §14 9+/10 게이트
// ============================================================
//
// 입력 (JSON):
// {
//   "에이전트ID": "rp_agent_eval_v1",
//   "대상유형": "블로그" | "견적" | "계약" | "SNS",
//   "대상ID": "string",
//   "대상내용": "string (채점 대상 텍스트)",
//   "평가루브릭": "blog_v1" | "quotation_v23" | "contract_v25" | "sns_v1"
// }
//
// 출력 (JSON):
// {
//   "점수": number (0-10),
//   "항목별점수": object,
//   "사유": string,
//   "HITL상태": "auto_pass" | "pending",
//   "기록ID": number
// }
// ============================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// ============================================================
// 루브릭 정의 (24번 카탈로그 정합)
// ============================================================
const RUBRICS: Record<string, { 항목: string[]; 임계: number }> = {
  blog_v1: {
    항목: [
      "헌법1.3_F5-N_네이버SEO",
      "F5-T_티스토리적합",
      "F6_본문_3000자",
      "F7_가독성",
      "G1_제목매력도",
      "G2_키워드밀도",
      "G3_사실정확성",
    ],
    임계: 9.0,
  },
  quotation_v23: {
    항목: [
      "거래처명_정확",
      "사업부_분류",
      "결제조건_50_50",
      "VAT_표기",
      "계좌_매핑",
      "약관_연결",
      "금액_합계",
      "옵션_매트릭스",
      "유효기간",
      "발신부_표준",
      "PDF_레이아웃",
    ],
    임계: 9.0,
  },
  contract_v25: {
    항목: [
      "을_표기_통일",
      "서명란_중복X",
      "위약금_표준",
      "별첨_손실X",
      "사업자번호_정확",
      "결제조건_명시",
      "기간_명시",
      "관할법원",
      "특약_조항",
    ],
    임계: 9.0,
  },
  sns_v1: {
    항목: [
      "G1_후크_3초",
      "G2_캡션_플랫폼적합",
      "G3_해시태그",
      "G4_CTA",
      "G5_길이_제한",
    ],
    임계: 9.0,
  },
};

// ============================================================
// Anthropic API 호출 (Haiku)
// ============================================================
async function callHaiku(prompt: string, supabase: any): Promise<string> {
  // 43차 룰: 외부 API 토큰 = Vault realplan_ prefix + service_role 헬퍼
  const { data: ANTHROPIC_KEY, error } = await supabase.rpc("realplan_get_secret", {
    secret_name: "realplan_anthropic_api_key",
  });
  if (error || !ANTHROPIC_KEY) throw new Error("ANTHROPIC_API_KEY 조회 실패 (Vault realplan_anthropic_api_key)");

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 1024,
      messages: [{ role: "user", content: prompt }],
    }),
  });

  if (!res.ok) throw new Error(`Anthropic API error: ${res.status}`);
  const data = await res.json();
  return data.content[0].text;
}

// ============================================================
// 채점 프롬프트 (Haiku용)
// ============================================================
function buildPrompt(대상유형: string, 대상내용: string, 항목: string[]): string {
  return `당신은 리얼플랜제주 주식회사의 산출물 채점 전문가입니다.

[채점 대상]
- 유형: ${대상유형}
- 내용:
${대상내용}

[채점 항목 (각 0~10점)]
${항목.map((a, i) => `${i + 1}. ${a}`).join("\n")}

[출력 형식 — JSON만]
{
  "항목별점수": { "${항목[0]}": 점수, ... },
  "총점": 평균,
  "사유": "한 단락 요약 (150자 이내)"
}

JSON만 출력하세요. 다른 텍스트 금지.`;
}

// ============================================================
// 메인 핸들러
// ============================================================
serve(async (req) => {
  // CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "authorization, content-type",
      },
    });
  }

  try {
    const body = await req.json();
    const { 에이전트ID, 대상유형, 대상ID, 대상내용, 평가루브릭 } = body;

    // 1) 입력 검증
    if (!에이전트ID || !대상유형 || !대상내용 || !평가루브릭) {
      return new Response(JSON.stringify({ error: "필수 입력 누락" }), { status: 400 });
    }
    const rubric = RUBRICS[평가루브릭];
    if (!rubric) {
      return new Response(JSON.stringify({ error: `루브릭 미정의: ${평가루브릭}` }), { status: 400 });
    }

    // 2) Supabase 클라이언트
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // 3) 비용 가드 (월 한도)
    const { data: budgetOK } = await supabase.rpc("rpc_check_agent_budget");
    if (!budgetOK) {
      return new Response(
        JSON.stringify({ error: "월 한도 초과 / Runbook §4.1 확인" }),
        { status: 429 }
      );
    }

    // 4) Haiku 채점
    const prompt = buildPrompt(대상유형, 대상내용, rubric.항목);
    const raw = await callHaiku(prompt, supabase);

    let parsed: any;
    try {
      parsed = JSON.parse(raw.trim().replace(/^```json|```$/g, "").trim());
    } catch (e) {
      throw new Error(`Haiku 응답 파싱 실패: ${raw.substring(0, 200)}`);
    }

    const 점수 = parsed.총점 ?? 0;
    const HITL상태 = 점수 >= rubric.임계 ? "auto_pass" : "pending";

    // 5) DB 적재 (hr_audit_handoff)
    const { data: inserted, error } = await supabase
      .from("hr_audit_handoff")
      .insert({
        에이전트ID,
        대상유형,
        대상ID,
        점수,
        항목별점수: parsed.항목별점수,
        사유: parsed.사유,
        평가루브릭,
        HITL상태,
      })
      .select("id")
      .single();

    if (error) throw error;

    // 6) 응답
    return new Response(
      JSON.stringify({
        점수,
        항목별점수: parsed.항목별점수,
        사유: parsed.사유,
        HITL상태,
        기록ID: inserted.id,
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
      }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});

// ============================================================
// 배포 전 점검 (Runbook §4 정합)
// ============================================================
// 1. sql/048 라이브 (hr_audit_handoff 테이블 생성됨)
// 2. Vault: ANTHROPIC_API_KEY 등록 (realplan_anthropic_api_key)
// 3. 환경변수: