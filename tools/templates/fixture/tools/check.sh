#!/bin/sh
# A scaffolded project's own sanity check.
#
# It exists in the CAP-10B0 fixture for one reason beyond being useful: it is
# the file that carries an intended POSIX executable mode, so the mode path
# through the registry, the writer and the verification is exercised by a
# real file rather than left as untested code.
set -eu

test -f pweb.json || { echo 'pweb.json is missing'; exit 1; }
test -d frontend  || { echo 'frontend/ is missing'; exit 1; }
test -d src       || { echo 'src/ is missing'; exit 1; }

echo 'project layout ok'
