#!/bin/sh

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# -----------------------------------------------------------------------------
# Tests the Cygwin/MinGW/MSYS2 path conversion performed by bin/mvn.
#
# The test runs on any POSIX platform: a throw-away Maven home is populated with
# the real bin/mvn, and uname(1), cygpath(1) and java(1) are stubbed out so that
# the Windows-only code paths can be exercised and the resulting JVM command
# line can be asserted upon.
#
# Usage: sh apache-maven/src/test/scripts/test-mvn-path-conversion.sh
#
# Exits with 0 when all assertions pass, 1 otherwise, so it can be wired into a
# CI job or a git hook as-is.
# -----------------------------------------------------------------------------

set -e

script_dir=`cd "\`dirname "$0"\`" && pwd`
mvn_script="$script_dir/../../assembly/maven/bin/mvn"

if [ ! -f "$mvn_script" ]; then
  echo "Cannot locate the mvn script at $mvn_script" >&2
  exit 1
fi

work_dir=`mktemp -d "${TMPDIR:-/tmp}/mvn-path-conversion.XXXXXX"`
trap 'rm -rf "$work_dir"' EXIT INT TERM

stub_dir="$work_dir/stubs"
maven_home="$work_dir/maven-home"
project_dir="$work_dir/project"

mkdir -p "$stub_dir" "$maven_home/bin" "$maven_home/boot" "$project_dir/.mvn" "$project_dir/module"

cp "$mvn_script" "$maven_home/bin/mvn"
touch "$maven_home/bin/m2.conf" "$maven_home/boot/plexus-classworlds-9.9.9.jar"

# uname(1) stub: the emulated OS is taken from the FAKE_UNAME variable.
cat > "$stub_dir/uname" <<'STUB'
#!/bin/sh
echo "${FAKE_UNAME:-Linux}"
STUB

# cygpath(1) stub: --windows maps /foo/bar to C:\foo\bar, --unix does the reverse.
cat > "$stub_dir/cygpath" <<'STUB'
#!/bin/sh
for arg in "$@"; do path="$arg"; done
case " $* " in
  *" --windows "*) printf 'C:%s\n' "`echo "$path" | tr '/' '\\\\'`" ;;
  *" --unix "*) echo "$path" | sed 's|^C:||' | tr '\\\\' '/' ;;
  *) echo "$path" ;;
esac
STUB

# java(1) stub: answers version probes, emulates JvmConfigParser and otherwise
# echoes the arguments it was invoked with, one bracketed token per argument.
cat > "$stub_dir/java" <<'STUB'
#!/bin/sh
case " $* " in
  *" -version "*|*" -version") exit 0 ;;
esac
case "$1" in
  *JvmConfigParser.java)
    # Mimics bin/JvmConfigParser: strip comments, expand the base directory
    # placeholders and print the arguments quoted. Plain string operations are
    # used throughout, since the base directory may contain backslashes that
    # sed/awk would interpret in a replacement.
    # Note: the base directory is passed through the environment, awk's -v would
    # interpret the backslashes of a Windows path as escape sequences.
    MAVEN_PROJECTBASEDIR="$3" awk '
      BEGIN { basedir = ENVIRON["MAVEN_PROJECTBASEDIR"] }
      function expand(text, placeholder,   result, pos) {
        result = ""
        while ((pos = index(text, placeholder)) > 0) {
          result = result substr(text, 1, pos - 1) basedir
          text = substr(text, pos + length(placeholder))
        }
        return result text
      }
      {
        sub(/#.*/, "")
        line = expand(expand($0, "${MAVEN_PROJECTBASEDIR}"), "$MAVEN_PROJECTBASEDIR")
        count = split(line, tokens, " ")
        for (i = 1; i <= count; i++) {
          if (tokens[i] != "") {
            printf "\"%s\" ", tokens[i]
          }
        }
      }
    ' "$2"
    exit 0 ;;
esac
for arg in "$@"; do printf '[%s]' "$arg"; done
echo
STUB

chmod +x "$stub_dir/uname" "$stub_dir/cygpath" "$stub_dir/java" "$maven_home/bin/mvn"

# A jvm.config referencing the project base directory, to assert that the value
# handed over to the JVM configuration is converted as well.
echo '-Xmx512m -Dtest.basedir=${MAVEN_PROJECTBASEDIR}' > "$project_dir/.mvn/jvm.config"

failures=0

# run_mvn <uname-output> <stub-dir>
run_mvn() {
  ( cd "$project_dir/module" &&
    FAKE_UNAME="$1" PATH="$2:$PATH" JAVA_HOME= MAVEN_SKIP_RC=1 \
      sh "$maven_home/bin/mvn" verify 2>/dev/null )
}

# contains <haystack> <needle>
# Plain substring check. A case/glob comparison cannot be used, the haystack
# holds Windows paths and backslashes are escape characters in glob patterns.
contains() {
  HAYSTACK="$1" NEEDLE="$2" awk '
    BEGIN { exit index(ENVIRON["HAYSTACK"], ENVIRON["NEEDLE"]) > 0 ? 0 : 1 }
  '
}

# assert_contains <description> <haystack> <needle>
assert_contains() {
  if contains "$2" "$3"; then
    printf 'ok - %s\n' "$1"
  else
    printf 'FAILED - %s\n' "$1"
    printf '  expected to contain: %s\n' "$3"
    printf '  actual: %s\n' "$2"
    failures=`expr $failures + 1`
  fi
}

# assert_not_contains <description> <haystack> <needle>
assert_not_contains() {
  if contains "$2" "$3"; then
    printf 'FAILED - %s\n' "$1"
    printf '  expected NOT to contain: %s\n' "$3"
    printf '  actual: %s\n' "$2"
    failures=`expr $failures + 1`
  else
    printf 'ok - %s\n' "$1"
  fi
}

# POSIX platforms must be left untouched.
output=`run_mvn Linux "$stub_dir"`
assert_contains "POSIX: multiModuleProjectDirectory stays a POSIX path" "$output" \
  "[-Dmaven.multiModuleProjectDirectory=$project_dir]"
assert_contains "POSIX: jvm.config placeholder stays a POSIX path" "$output" \
  "[-Dtest.basedir=$project_dir]"

# Every Windows POSIX emulation layer must receive native Windows paths.
for os in CYGWIN_NT-10.0 MINGW32_NT-6.2 MINGW64_NT-10.0 MSYS_NT-10.0; do
  output=`run_mvn "$os" "$stub_dir"`
  windows_basedir=`echo "$project_dir" | tr '/' '\\\\'`

  assert_contains "$os: multiModuleProjectDirectory is a native Windows path" "$output" \
    "[-Dmaven.multiModuleProjectDirectory=C:$windows_basedir]"
  assert_contains "$os: jvm.config placeholder is a native Windows path" "$output" \
    "[-Dtest.basedir=C:$windows_basedir]"
  assert_contains "$os: maven.home is a native Windows path" "$output" \
    "[-Dmaven.home=C:`echo "$maven_home" | tr '/' '\\\\'`]"
  assert_contains "$os: library.jline.path is a native Windows path" "$output" \
    "[-Dlibrary.jline.path=C:`echo "$maven_home/lib/jline-native" | tr '/' '\\\\'`]"
  assert_not_contains "$os: no path mixes both separators" "$output" "\\/"
done

# Without cygpath the launcher must still work, using unconverted paths.
nocygpath_dir="$work_dir/stubs-without-cygpath"
mkdir -p "$nocygpath_dir"
cp "$stub_dir/uname" "$stub_dir/java" "$nocygpath_dir"

output=`run_mvn MINGW64_NT-10.0 "$nocygpath_dir"`
assert_contains "missing cygpath: launcher falls back to POSIX paths" "$output" \
  "[-Dmaven.multiModuleProjectDirectory=$project_dir]"

if [ "$failures" -ne 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi

echo "All assertions passed"
