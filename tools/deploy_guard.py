#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
deploy_guard.py — 배포 회귀 방지 게이트 v1.0 (2026-08-05)

왜 만들었나
-----------
2026-08-04 18:00 커밋 b938974(「편성안 탭 신설」)가 **v1.9.5 구본을 기준으로 편집**돼
8/1 v1.10.0의 「미디어 관리」 236줄을 통째로 지웠다. 화면에서 음악 43곡·영상 설계 9편이
4일간 사라져 있었는데 아무도 몰랐다. 같은 계열 사고가 이미 두 번 있었다(톤배지 부활, admin 꼬리잘림).

이 스크립트는 배포 직전에 두 가지만 본다.
  ① 기준(base)이 진짜 라이브인가          → --base 를 GitHub 원격에서 받게 강제
  ② 새 파일이 기준보다 기능이 줄지 않았나  → 지문(fingerprint) 대조

사용법
------
  python3 tools/deploy_guard.py --path admin/marketing.html --new /tmp/new.html
  (기준은 origin/main 에서 자동으로 가져온다. --base 로 파일 지정도 가능)

  의도적으로 지우는 경우에만:
  ... --allow-remove "id:md-bgm" --allow-remove "fn:mediaInit"

종료코드: 0=통과 / 1=회귀 발견(배포 금지) / 2=구조 오류(배포 금지)
"""
import argparse, base64, collections, json, re, subprocess, sys, tempfile, os

# ── 지문 추출 ────────────────────────────────────────────────────────────
PATS = [
    ("id",    re.compile(r'\sid="([A-Za-z0-9_\-]+)"')),                       # 화면 요소
    ("fn",    re.compile(r'(?:function\s+|window\.)([A-Za-z_$][\w$]*)\s*(?:=\s*(?:async\s*)?function|\()')),
    ("tbl",   re.compile(r"\.from\(\s*['\"]([A-Za-z0-9_]+)['\"]")),           # Supabase 테이블·뷰
    ("rpc",   re.compile(r"\.rpc\(\s*['\"]([A-Za-z0-9_]+)['\"]")),            # RPC
    ("ef",    re.compile(r"functions\.invoke\(\s*['\"]([A-Za-z0-9_\-]+)['\"]")),
    ("nav",   re.compile(r'nav-item[^>]*title="([^"]+)"')),                   # 사이드바 메뉴
    ("panel", re.compile(r'class="tab-panel"\s+id="([A-Za-z0-9_\-]+)"')),
]

def prints(txt):
    out = {}
    for kind, rx in PATS:
        for m in rx.findall(txt):
            out[f"{kind}:{m}"] = out.get(f"{kind}:{m}", 0) + 1
    return out

def version_of(txt):
    m = re.search(r'hdr-badge">v([\d.]+)<', txt) or re.search(r'<title>[^<]*v([\d.]+)</title>', txt)
    return m.group(1) if m else None

def vtuple(v):
    return tuple(int(x) for x in v.split(".")) if v else ()

# ── 구조 검사 ────────────────────────────────────────────────────────────
def structure_errors(txt):
    errs = []
    if not txt.rstrip().endswith("</html>"):
        errs.append("파일 끝이 </html> 가 아니다 (꼬리 잘림 — admin 로그인 불능 사고의 원인)")
    try:
        from lxml import html as LH
        LH.fromstring(txt)
    except ImportError:
        errs.append("lxml 미설치 — pip install lxml --break-system-packages")
    except Exception as e:
        errs.append(f"HTML 파싱 실패: {e}")
    ids = re.findall(r'\sid="([A-Za-z0-9_\-]+)"', txt)
    dup = sorted(i for i, n in collections.Counter(ids).items() if n > 1)
    if dup:
        errs.append(f"중복 id {len(dup)}개: {', '.join(dup[:8])}")
    for i, js in enumerate(re.findall(r"<script(?:\s[^>]*)?>(.*?)</script>", txt, re.S)):
        if not js.strip():
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
            f.write(js); p = f.name
        r = subprocess.run(["node", "--check", p], capture_output=True, text=True)
        os.unlink(p)
        if r.returncode:
            errs.append(f"script[{i}] 구문 오류: {r.stderr.strip().splitlines()[0][:160]}")
    return errs

# ── 기준(base) 조달 ──────────────────────────────────────────────────────
def base_from_git(path, ref="origin/main"):
    subprocess.run(["git", "fetch", "-q", "origin", "main"], check=False)
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True)
    if r.returncode:
        sys.exit(f"[중단] 기준 파일을 원격에서 못 읽었다: {ref}:{path}")
    return r.stdout.decode("utf-8")

# ── 본체 ────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", required=True, help="레포 내 경로 (예: admin/marketing.html)")
    ap.add_argument("--new", required=True, help="배포할 새 파일")
    ap.add_argument("--base", help="기준 파일(생략 시 origin/main에서 자동)")
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--allow-remove", action="append", default=[], help='의도적 삭제 허용 (예: "fn:oldThing")')
    a = ap.parse_args()

    new = open(a.new, encoding="utf-8").read()
    base = open(a.base, encoding="utf-8").read() if a.base else base_from_git(a.path, a.ref)

    print(f"■ 대상 {a.path}")
    print(f"  기준 {len(base.encode()):,}B (v{version_of(base) or '?'})  →  신규 {len(new.encode()):,}B (v{version_of(new) or '?'})")

    fail = []

    # ① 버전 역행
    vb, vn = version_of(base), version_of(new)
    if vb and vn and vtuple(vn) < vtuple(vb):
        fail.append(f"버전 역행: v{vb} → v{vn}  (구본을 기준으로 편집했다는 가장 확실한 신호)")

    # ② 기능 회귀 = 기준에 있던 지문이 신규에서 0이 됨
    pb, pn = prints(base), prints(new)
    allow = set(a.allow_remove)
    gone = sorted(k for k in pb if k not in pn and k not in allow)
    if gone:
        by = collections.defaultdict(list)
        for g in gone:
            by[g.split(":", 1)[0]].append(g.split(":", 1)[1])
        fail.append("기능 회귀 " + str(len(gone)) + "건 — 기준에 있던 것이 신규에서 사라졌다")
        for k, v in by.items():
            print(f"    ✗ {k:6s} {len(v)}건: {', '.join(v[:12])}{' …' if len(v) > 12 else ''}")

    # ③ 구조
    errs = structure_errors(new)
    fail += errs

    added = sorted(k for k in pn if k not in pb)
    print(f"  추가된 지문 {len(added)}건" + (f" (예: {', '.join(added[:6])})" if added else ""))

    if fail:
        print("\n■ 판정: 배포 금지 ⛔")
        for f in fail:
            print("   -", f)
        print("\n  → 구본 기준 편집이면 라이브를 다시 받아 그 위에 패치할 것.")
        print("  → 정말 지우는 게 맞으면 --allow-remove 로 하나씩 명시할 것(무더기 허용 금지).")
        return 1
    print("\n■ 판정: 통과 ✅  (회귀 없음 · 구조 정상)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
