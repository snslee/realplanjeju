// mk-blog-fullauto v11 (DEPRECATED STUB) — 2026-05-20 / 40차·47차 권고 정합
// 원인: 학습 자료 미정독 / 본문 1점 글 / EF 10번 배포 사고
// 재시작 조건:
//   1. 스킬 24편 풀 정독
//   2. mk-admin.html UI 1개 이상 가동
//   3. 노션·xlsx·Supabase SSoT 결정 (단일화)
//   4. agent-evaluate Haiku 4.5 채점 9+/10 PASS
//   5. §14 4단계 게이트 통과
//
// 원본 v9 (2026-05-06 / 25,851 bytes) 백업 위치:
// D:\자동화\회사 시스템 및 개발 사업부\_삭제예정\2026-05-20_정리\edge_functions\mk-blog-fullauto_v9_폐기_2026-05-20\index.ts

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

Deno.serve(async (_req: Request) => {
  return new Response(
    JSON.stringify({
      ok: false,
      error: "GONE",
      status: 410,
      message: "mk-blog-fullauto v1~v10 폐기됨 (2026-05-20). 재시작은 47차 권고 5건 충족 후만.",
      docs: "D:\\자동화\\회사 시스템 및 개발 사업부\\50_P5_온라인마케팅시스템\\03_폐기\\풀오토_v1_v2.3_실패본",
      replacement: "P5 풀오토 재신규는 47차 권고 정합 후 새 EF",
    }, null, 2),
    {
      status: 410,
      headers: { "Content-Type": "application/json", "X-Deprecated-At": "2026-05-20" },
    }
  );
});
