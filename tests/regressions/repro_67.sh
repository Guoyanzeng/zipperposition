#!/usr/bin/env sh
exec ./zipperposition.exe  --timeout 60   --tptp-def-as-rewrite --rewrite-before-cnf=true    --boolean-reasoning=cases-simpl --ho-prune-arg=old-prune   --ho-neg-cong-fun --ho-neg-ext=true --simultaneous-sup=false --ho-prim-enum=none   -q "1|prefer-easy-ho|default"   -q "1|prefer-ho-steps|conjecture-relative-var(1.03,s,f)"   -q "1|prefer-sos|default"   -q "5|const|conjecture-relative-var(1.01,l,f)"   -q "1|prefer-processed|fifo"   -q "1|prefer-non-goals|conjecture-relative-var(1.05,l,f)"   -q "1|prefer-fo|conjecture-relative-var(1.1,s,f)"   --select=e-selection5 --recognize-injectivity=true --ho-choice-inst=true --ho-selection-restriction=none  --check --dot-llproof /tmp/truc.dot tests/regressions/CSR132^1.p $@

# --debug.llproof 25 
