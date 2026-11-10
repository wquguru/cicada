#!/bin/zsh
# ming.sh <repo> <wav...>: each file through the real press pipeline (lsctl speakFile: on-device + Ming),
# printing what each heard (the WIP-AEC log line) and Ming's Chinese kept / English leaked.
cd "${0:A:h}"
L=$1/tools/lsctl; LOG=/tmp/livesubs-dev-debug.log; shift
NEAR="我同意这个数字。设计那个岗位很急，周四之前我会回复。"
TEXT="Thanks everyone for joining. Our revenue grew twelve percent this quarter, mostly from enterprise customers in Europe. Marketing spent less than planned, and we hired four engineers. Next month we will launch the new pricing page and review the hiring plan for the second half of the year."
$L speakOn >/dev/null; sleep 4
for f in $@; do
  mark=$(wc -l < $LOG)
  $L speakFile:${f:A} >/dev/null
  sleep 3
  $L --wait 'speak.phase == "idle"' --timeout 90 >/dev/null; sleep 1
  heard=$(tail -n +$((mark + 1)) $LOG | grep -a "WIP-AEC heard" | tail -1 | sed 's/.*ming=\[//; s/\]$//')
  python3 -I - "$NEAR" "$TEXT" "$heard" "${f:t}" <<'EOF'
import re, sys
near, text, heard, name = sys.argv[1:5]
want = [c for c in near if '一' <= c <= '鿿']; pool = [c for c in heard if '一' <= c <= '鿿']; zh = 0
for c in want:
    if c in pool: pool.remove(c); zh += 1
ew = re.findall(r"[a-z]+", text.lower()); pool = re.findall(r"[a-z]+", heard.lower()); en = 0
for w in ew:
    if w in pool: pool.remove(w); en += 1
# The meeting leaks back as Ming's Chinese translation of it: count its key terms.
terms = ["收入", "季度", "百分之十二", "12%", "欧洲", "企业客户", "营销", "工程师", "定价", "招聘", "下半年", "参加"]
leak = sum(t in heard for t in terms)
print(f"{name}: Ming {zh}/{len(want)}字, meeting terms {leak}/{len(terms)}, {en} English  [{heard}]")
EOF
done
$L speakOff >/dev/null
