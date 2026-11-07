#!/usr/bin/env bash
# Adds integrity (SRI) hashes to the two Supabase <script> tags in index.html.
# Run ONCE on a computer with internet, curl, openssl and python3:   bash add-sri.sh
# It refuses to change anything if the two CDNs do not serve identical files.
set -euo pipefail
cd "$(dirname "$0")"
V=2.58.0
A="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@$V/dist/umd/supabase.min.js"
B="https://unpkg.com/@supabase/supabase-js@$V/dist/umd/supabase.min.js"
ha=$(curl -fsSL "$A" | openssl dgst -sha384 -binary | openssl base64 -A)
hb=$(curl -fsSL "$B" | openssl dgst -sha384 -binary | openssl base64 -A)
if [ "$ha" != "$hb" ]; then echo "The two CDNs returned different files. Not changing anything."; exit 1; fi
python3 - "$A" "$B" "sha384-$ha" <<'EOF'
import sys
a,b,h=sys.argv[1:4]
s=open('index.html',encoding='utf-8').read()
for u in (a,b):
    old='src="%s"'%u
    new='src="%s" integrity="%s" crossorigin="anonymous"'%(u,h)
    if 'integrity=' in s.split(old)[1][:80] if old in s else False:
        continue
    if old not in s: print("not found:",u); continue
    s=s.replace(old,new)
open('index.html','w',encoding='utf-8').write(s)
print("Done. integrity =",h)
EOF
