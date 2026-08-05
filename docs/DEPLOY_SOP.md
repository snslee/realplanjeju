# 화면 배포 SOP v1.0 (2026-08-05 · 대표 승인)

> 이 문서가 생긴 이유: **구본을 기준으로 편집해 배포한 사고가 세 번 났다.**
> ① admin.html 꼬리 잘림(로그인 불능) ② 폐기한 톤배지 부활 ③ **8/4 편성안 커밋이 미디어 관리 236줄 삭제(4일간 방치)**
> 세 번 다 원인이 같다. **정본은 GitHub 라이브, D드라이브는 백업이다.**

---

## 0. 절대 규칙 3줄

1. 편집의 **기준 파일은 항상 원격(`origin/main`)에서 새로 받는다.** D드라이브·이전 대화의 파일을 기준으로 삼지 않는다.
2. 배포 전 **`tools/deploy_guard.py` 통과(종료코드 0)가 없으면 푸시하지 않는다.**
3. 배포 직전 라이브본을 **`admin/_삭제예정/<파일>_<사유>_<YYYYMMDD>.html` 로 같은 배치에 함께 커밋**한다.

---

## 1. 절차

| 단계 | 하는 일 | 실패 시 |
|---|---|---|
| 1 | `git fetch origin main` → `git show origin/main:<경로>` 로 **기준 확보** | 못 받으면 중단 |
| 2 | 기준 위에 패치. 버전 배지·`<title>` 둘 다 올린다(내리지 않는다) | — |
| 3 | `python3 tools/deploy_guard.py --path <경로> --new <새파일>` | **1이면 배포 금지** |
| 4 | 백업본 + 새 파일을 **한 배치로** `github-push` EF에 PUT | 실패 시 재시도(부분 배포 금지) |
| 5 | `git fetch` 후 원격 파일 sha256 == 로컬 빌드본 sha256 대조 | 불일치면 롤백 |
| 6 | 브라우저 `Ctrl+Shift+R` 후 **실화면 눈으로 확인** — 버전 배지·해당 탭·직전 기능 1개 | 이상 시 백업본으로 롤백 |

## 2. deploy_guard 가 보는 것

| 검사 | 내용 | 8/4 사고에서 |
|---|---|---|
| **버전 역행** | 배지·title의 `vX.Y.Z` 가 기준보다 낮으면 차단 | v1.10.0 → v1.9.5 **적발** |
| **기능 회귀** | 기준에 있던 지문이 신규에서 **0건**이면 차단<br>지문 = `id` / 함수명 / `.from(테이블)` / `.rpc()` / EF명 / 사이드바 title / tab-panel | 30건 **적발**<br>(mediaInit·mk_bgm_library·mk_video_designs·md-* 10개·미디어 관리 메뉴) |
| **구조** | 끝 `</html>` · lxml 파싱 · `<script>` 전량 `node --check` · 중복 id | 꼬리잘림 사고 대비 |

의도적으로 지우는 항목은 `--allow-remove "fn:이름"` 처럼 **하나씩 명시**한다. 무더기 허용 금지.

## 3. 롤백

```bash
git show origin/main:admin/_삭제예정/marketing_<사유>_<날짜>.html > /tmp/rollback.html
# → github-push EF 로 admin/marketing.html 에 PUT
```

## 4. 배포 경로 메모

- `git push` 는 컨테이너·기기 양쪽에서 **막혀 있다**(프록시 자격증명 미주입). 정상 경로는 **`github-push` EF**(Vault PAT 서버측 사용, `verify_jwt=false`).
- GitHub Pages 반영 1~5분. 확인은 `https://realplanjeju.com/admin/marketing.html` (marketing.realplanjeju.com은 **다른 화면**).
