#!/bin/sh
#
# Walk the module against a tracker and a storage node, for real: fetch a
# key, fetch one that is stored three times, meet every error the tracker
# can return, and write a key through create_open and create_close.
#
#     ci/mogtest.sh 1.30.6
#
# The tracker is t/tracker.pl, which speaks the line protocol and nothing
# else.  The storage node is a second server block in the same nginx, with
# dav so that the write path has somewhere to PUT to.
#
# Why the write path is worth this much scaffolding: the 1.0.4 tarball,
# which is what the FreeBSD port has been building, is missing the
# reference counting the author added afterwards.  Without r->main->count++
# nginx finishes the request while the module is still working on it.

set -eu

NGINX=${1:?nginx version missing}

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}
PREFIX=$WORK/mog-$NGINX

TRACKER_PORT=${TRACKER_PORT:-7001}
STORE_PORT=${STORE_PORT:-18082}
HTTP_PORT=${HTTP_PORT:-18080}

"$SRC/ci/build.sh" "$NGINX" "$PREFIX"

ROOT=$PREFIX/store
mkdir -p "$PREFIX/conf" "$PREFIX/logs" "$ROOT/dev1/0/000/000" \
	"$ROOT/dev2/0/000/000" "$ROOT/dev3/0/000/000"

# printf, not echo -n: whether echo understands -n depends on the shell,
# and the one that does not writes the flag into the file.
printf 'contents of key one'   > "$ROOT/dev1/0/000/000/0000000001.fid"
printf 'contents of key three' > "$ROOT/dev3/0/000/000/0000000002.fid"
# dev1 and dev2 are deliberately left without 0000000002.fid, so a client
# asking for the thrice-stored key only gets an answer if the module hands
# out more than the first path.

cat > "$PREFIX/conf/nginx.conf" <<EOF
daemon off;
master_process off;
error_log $PREFIX/logs/error.log info;
pid $PREFIX/logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    default_type application/octet-stream;

    # the stand-in storage node
    server {
        listen 127.0.0.1:$STORE_PORT;
        root $ROOT;
        location / {
            dav_methods PUT DELETE;
            create_full_put_path on;
        }
    }

    server {
        listen 127.0.0.1:$HTTP_PORT;

        location /download/ {
            mogilefs_tracker 127.0.0.1:$TRACKER_PORT;
            mogilefs_domain  test;

            # Two seconds, not the default sixty, so that a request which
            # ends in the read timeout instead of on the tracker's answer
            # shows up as a measurable delay rather than a hung run.  The
            # checks below hold every answer to well under this.
            mogilefs_read_timeout 2s;

            mogilefs_pass {
                proxy_pass \$mogilefs_path;
                proxy_hide_header Content-Type;
                proxy_intercept_errors on;
            }
        }

        # Three paths for one key.  proxy_pass with a variable is a single
        # destination, so there is nothing here for proxy_next_upstream to
        # choose between; the copies are handed over as \$mogilefs_path1 and
        # \$mogilefs_path2, for a configuration to walk itself.
        #
        # Rather than walking them, this reads them back: the variables go
        # out as headers, so the checks below see which paths the module
        # filled in and in which order, and a regression that drops the
        # spares or shuffles them is visible instead of merely likely.  The
        # third copy is fetched by name in /thirdcopy/ below.
        location /spares/ {
            mogilefs_tracker 127.0.0.1:$TRACKER_PORT;
            mogilefs_domain  test;
            mogilefs_pass {
                proxy_pass \$mogilefs_path;
                proxy_hide_header Content-Type;
                proxy_intercept_errors on;
                add_header X-Copy-1 \$mogilefs_path  always;
                add_header X-Copy-2 \$mogilefs_path1 always;
                add_header X-Copy-3 \$mogilefs_path2 always;
                add_header X-Copy-4 \$mogilefs_path3 always;
                error_page 404 = @gone;
            }
        }

        location @gone {
            internal;
            add_header X-Copy-1 \$mogilefs_path  always;
            add_header X-Copy-2 \$mogilefs_path1 always;
            add_header X-Copy-3 \$mogilefs_path2 always;
            add_header X-Copy-4 \$mogilefs_path3 always;
            return 204;
        }

        # Only dev3 has the file, so fetching the third copy by name is the
        # proof that \$mogilefs_path2 holds a usable URL and not just text.
        location /thirdcopy/ {
            mogilefs_tracker 127.0.0.1:$TRACKER_PORT;
            mogilefs_domain  test;
            mogilefs_pass {
                proxy_pass \$mogilefs_path2;
                proxy_hide_header Content-Type;
            }
        }

        location /other/ {
            mogilefs_tracker 127.0.0.1:$TRACKER_PORT;
            mogilefs_domain  nosuchdomain;
            mogilefs_pass {
                proxy_pass \$mogilefs_path;
            }
        }

        location = /stub {
            stub_status;
            access_log off;
        }

        location /rw/ {
            mogilefs_tracker 127.0.0.1:$TRACKER_PORT;
            mogilefs_domain  test;
            mogilefs_methods GET PUT DELETE;
            mogilefs_pass {
                proxy_pass \$mogilefs_path;
                proxy_hide_header Content-Type;
            }
        }
    }
}
EOF

cleanup() {
	[ -n "${nginx_pid:-}" ] && kill "$nginx_pid" 2>/dev/null
	[ -n "${tracker_pid:-}" ] && kill "$tracker_pid" 2>/dev/null
	wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

perl "$SRC/t/tracker.pl" --port "$TRACKER_PORT" \
	--store "http://127.0.0.1:$STORE_PORT" > "$WORK/tracker.log" 2>&1 &
tracker_pid=$!

"$PREFIX/sbin/nginx" -p "$PREFIX" -c conf/nginx.conf > "$WORK/nginx.log" 2>&1 &
nginx_pid=$!

# Wait for both, rather than sleeping for a number that is either too
# small on a loaded runner or wasted everywhere else.  The probe goes
# through perl because /dev/tcp is a bash extension and /bin/sh is dash on
# the runners, and because perl is here anyway for the tracker.
listening() {
	perl -MIO::Socket::INET -e 'exit(IO::Socket::INET->new(
		PeerAddr => "127.0.0.1", PeerPort => $ARGV[0],
		Proto => "tcp", Timeout => 1) ? 0 : 1)' "$1"
}

i=0
while [ "$i" -lt 100 ]; do
	if listening "$HTTP_PORT" && listening "$TRACKER_PORT"; then
		break
	fi
	i=$((i + 1))
	sleep 0.1
done
[ "$i" -lt 100 ] || { echo "ci/mogtest.sh: nginx or the tracker never came up" >&2; cat "$WORK/nginx.log" "$WORK/tracker.log"; exit 1; }

fail=0

# check <name> <expected status> <expected body or -> <curl arguments...>
#
# --max-time is not politeness, it is part of the check.  An answer that
# only arrives once mogilefs_read_timeout expires is a failure, not a slow
# pass, and without a bound here the run would sit in it instead of saying
# so.  The limit is well above any honest answer on a loopback.
check() {
	name=$1; want_status=$2; want_body=$3; shift 3

	out=$(curl -s --max-time 5 -o "$WORK/body" -w '%{http_code} %{time_total}' "$@" 2>/dev/null) || {
		echo "not ok - $name (no answer within 5s, or curl itself failed)"
		fail=$((fail + 1)); return
	}
	spent=${out#* }
	out=${out%% *}
	body=$(cat "$WORK/body")

	# An answer that waited out mogilefs_read_timeout is wrong even when
	# its status is right.  Up to 1.0.4 every tracker error other than a
	# 404 did exactly that: the status reached the client at once and the
	# worker then sat in the timeout behind it, because the module put the
	# body length on r->headers_out instead of u->headers_in.  The
	# location above sets that timeout to two seconds, so half of it is a
	# ceiling no honest loopback answer comes near.
	if [ "${spent%%.*}" -ge 1 ]; then
		echo "not ok - $name: took ${spent}s, which means it waited for the read timeout"
		fail=$((fail + 1))
		return
	fi

	if [ "$out" != "$want_status" ]; then
		echo "not ok - $name: status $out, wanted $want_status"
		fail=$((fail + 1))
		return
	fi
	if [ "$want_body" != - ] && [ "$body" != "$want_body" ]; then
		echo "not ok - $name: body \"$body\", wanted \"$want_body\""
		fail=$((fail + 1))
		return
	fi
	echo "ok - $name"
}

base=http://127.0.0.1:$HTTP_PORT

echo "--- reading ---"
check "a stored key is served"           200 'contents of key one' "$base/download/one"
check "an unknown key is 404"            404 -                     "$base/download/missing"
check "a HEAD on a stored key"           200 -                     -I "$base/download/one"

echo "--- the tracker's errors ---"
check "no_devices becomes 503"           503 -                     "$base/download/err-no_devices"
check "no_key becomes 400"               400 -                     "$base/download/err-no_key"
check "unreg_class becomes 400"          400 -                     "$base/download/err-unreg_class"
check "a wrong domain is 404"            404 -                     "$base/other/one"

echo "--- more than one path for a key ---"
check "the third copy is reachable"      200 'contents of key three' "$base/thirdcopy/three"

# The tracker answered with three paths, in the order dev1, dev2, dev3.
# $mogilefs_path has to be the first and the spares the rest, in that
# order; $mogilefs_path3 has to stay empty, because there is no fourth.
curl -s --max-time 5 -o /dev/null -D "$WORK/spares" "$base/spares/three" 2>/dev/null
spare_header() { sed -n "s/^$1: //Ip" "$WORK/spares" | tr -d '\r'; }

for want in 1:dev1 2:dev2 3:dev3; do
	n=${want%:*}; dev=${want#*:}
	got=$(spare_header "X-Copy-$n")
	case $got in
	*"/$dev/"*) echo "ok - copy $n is on $dev" ;;
	*)          echo "not ok - copy $n is \"$got\", expected a path on $dev"
	            fail=$((fail + 1)) ;;
	esac
done

if [ -z "$(spare_header X-Copy-4)" ]; then
	echo "ok - there is no fourth copy"
else
	echo "not ok - a fourth copy appeared: $(spare_header X-Copy-4)"
	fail=$((fail + 1))
fi

echo "--- writing ---"
check "PUT stores a key"                 201 -  -X PUT --data-binary 'written by the test' \
                                                "$base/rw/written"
check "and the key reads back"           200 'written by the test'  "$base/rw/written"
check "the written key has one copy"     200 -                      "$base/rw/written"
check "DELETE removes it"                204 -  -X DELETE           "$base/rw/written"
check "and it is gone"                   404 -                      "$base/rw/written"

# A tracker on the far side of a network is not a trusted source of well
# formed lines.  t/tracker.pl answers a key starting with "raw-" with a
# malformed one, and the shapes below are the two that used to be fatal:
#
#   "a=1&&b=2" and a leading "&" left an empty parameter between two
#   separators.  The parameter loop stepped over the separator only when
#   the parameter before it was not empty, so for an empty one it spun at
#   that position, at full CPU, for ever, with nothing in the error log.
#   The ceiling inside check() is what catches it: a spinning worker never
#   answers, and curl gives up after five seconds.
#
#   A parameter with no "=" sent ngx_strchr past the end of the upstream
#   buffer, which carries what the network delivered and is not
#   terminated.  Where it found an "=" beyond the line, the length
#   computed from it went negative, became a very large size_t, and
#   ngx_unescape_uri then wrote over that length.  A refusal is the right
#   answer here, and a refusal is what is asserted.
# Last, deliberately: a worker that spins answers nothing afterwards
# either, so these in front would have reported every later check as a
# failure of its own and buried what actually broke.
echo "--- malformed tracker lines ---"
check "an empty parameter is stepped over"   200 'contents of key one' "$base/download/raw-empty-param"
check "a leading separator too"              200 'contents of key one' "$base/download/raw-leading-amp"
check "a parameter without = is refused"     500 -                     "$base/download/raw-no-equals"
check "also with a good one behind it"       500 -                     "$base/download/raw-no-equals-mid"
check "a line of separators has no paths"    503 -                     "$base/download/raw-only-amps"

echo "--- nothing left behind in the worker ---"
#
# A reference count raised once too often does not fail a request.  The
# client gets its answer and the request stays in the worker with its
# connection, which is what the merge 020937f did to the write path: it
# took the increment from both of its parents and left two of them in the
# FETCH branch.  Nothing in the checks above notices that, so count what
# is still open.
#
# stub_status' "Active connections" includes the connection asking for it,
# so the figure to compare is "reading + writing + waiting" against what
# it was before the writes.
stub() {
	curl -s --max-time 5 "$base/stub" 2>/dev/null |
		sed -n 's/^Reading: \([0-9]*\) Writing: \([0-9]*\) Waiting: \([0-9]*\).*/\1 \2 \3/p' |
		awk '{print $1 + $2 + $3}'
}

before=$(stub)

i=0
while [ "$i" -lt 20 ]; do
	curl -s --max-time 5 -o /dev/null -X PUT --data-binary 'leak check' \
		"$base/rw/leak-$i" 2>/dev/null
	i=$((i + 1))
done

# The malformed lines above go through here as well.  Their checks say
# the module answers and does not spin; whether a request is left behind
# on those error paths is a different question, and this is where it can
# be asked, because the figure is taken after them rather than before.
i=0
while [ "$i" -lt 5 ]; do
	for shape in empty-param leading-amp no-equals no-equals-mid only-amps; do
		curl -s --max-time 5 -o /dev/null \
			"$base/download/raw-$shape" 2>/dev/null
	done
	i=$((i + 1))
done

# Give the worker a moment to let go of the keepalive connections curl
# left behind; without this the figure below counts those instead.
sleep 1
after=$(stub)

echo "    open before: $before, after twenty writes and twenty-five malformed lines: $after"

if [ -z "$before" ] || [ -z "$after" ]; then
	echo "not ok - could not read stub_status"
	fail=$((fail + 1))
elif [ "$after" -gt $((before + 2)) ]; then
	echo "not ok - the rounds left $((after - before)) requests open in the worker"
	fail=$((fail + 1))
else
	echo "ok - the writes and the malformed lines left nothing open"
fi

echo "--- nginx still healthy? ---"
if kill -0 "$nginx_pid" 2>/dev/null; then
	echo "ok - nginx is still running"
else
	echo "not ok - nginx died during the run"
	fail=$((fail + 1))
	tail -40 "$PREFIX/logs/error.log" 2>/dev/null
fi

# A worker that was taken down and restarted leaves this behind even when
# every request above still got an answer, so it is worth its own check.
if grep -qE '\[(alert|emerg)\]|signal 11|signal 6' "$PREFIX/logs/error.log" 2>/dev/null; then
	echo "not ok - the error log has an alert in it"
	grep -E '\[(alert|emerg)\]|signal 11|signal 6' "$PREFIX/logs/error.log" | head -5
	fail=$((fail + 1))
else
	echo "ok - no alert in the error log"
fi

if [ "$fail" -ne 0 ]; then
	echo "ci/mogtest.sh: $fail check(s) failed" >&2
	exit 1
fi

echo "ci/mogtest.sh: all checks passed"
