#!/bin/bash
# bench/run.sh [--quick] [--out DIR] [--data DIR] [--repeats N]
#              [--n "N ..."] [--threads "T ..."] [--engines "E ..."]
#              [--timeout SECONDS]
# Run benchmark round 1 and write its report: docs/benchmarks/README.md.
# Needs SBCL with Quicklisp, Kyoto Cabinet 1.2.80, python3, and
# cl-kyoto-cabinet in $CL_KYOTO_CABINET (default ~/work/cl-kyoto-cabinet).
set -euo pipefail
cd "$(dirname "$0")/.."
args=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) args="$args :quick t" ;;
    --out) args="$args :out \"$2\""; shift ;;
    --data) args="$args :data \"$2\""; shift ;;
    --repeats) args="$args :repeats $2"; shift ;;
    --timeout) args="$args :timeout $2"; shift ;;
    --n) args="$args :ns '($2)"; shift ;;
    --threads) args="$args :threads '($2)"; shift ;;
    --engines) args="$args :engines '($(echo "$2" | sed -E 's/([a-z-]+)/:\1/g'))"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
kc="${CL_KYOTO_CABINET:-$HOME/work/cl-kyoto-cabinet}"
exec sbcl --noinform --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval "(push (truename \"$kc/\") asdf:*central-registry*)" \
  --eval '(asdf:load-system :vivace-cabinet/bench)' \
  --eval "(vivace-cabinet-bench:main $args)"
