#!/usr/bin/env bash
# Fails when a workflow, or a local action under .github, refers to an action
# by anything other than a full commit SHA. A tag or a branch can be moved to
# different code after review. A full commit SHA cannot.
#
# This is a lint against mistakes, such as a person, an agent or a bot adding
# "@v4". It is not a security boundary: someone who can edit a workflow can
# also delete this check.
#
# The script reads lines, not YAML. It checks the key written plainly, as
# "uses:" or "- uses:", and reports what it cannot read instead of trusting
# it: a flow-style mapping, a value on the following line, a YAML line break
# inside a line, and also a script line inside a "run:" block that itself
# starts with "uses:". YAML has rarer ways to write the same key (an anchor, a
# tag or an alias on the key, an explicit "?" key, escapes inside a quoted
# key) that this script does not read: write "uses:" plainly. GitHub's own
# setting "Require actions to be pinned to a full-length commit SHA" applies
# the same rule with a full YAML parser.
#
# Usage: check-action-pins.sh [directory ...]
# With no arguments it scans .github in the repository that holds this script.
# Exit status: 0 everything is pinned, 1 something is not, 2 it could not scan.

set -u
export LC_ALL=C # match bytes and sort the same way on every system
die() { echo "check-action-pins: $*" >&2; exit 2; }

if [ "$#" -eq 0 ]; then
  CDPATH='' cd -- "$(dirname -- "$0")/../.." || exit 2
  set -- .github
fi
dirs=()
for dir in "$@"; do
  [ -d "$dir" ] || die "not a directory: $dir"
  case $dir in
    -*) dir=./$dir ;;
  esac
  dirs[${#dirs[@]}]=$dir
done

# A reference is a line where "uses" is a mapping key: in block style
# ("uses:", "- uses:") or inside a flow collection ("{uses:", ", uses:",
# "[uses:"). A line whose first non-space character is "#" is a comment.
key="[\"']?uses[\"']?[[:space:]]*:"
block="^[[:space:]]*(-[[:space:]]+)*$key"
reference="$block|[{,[][[:space:]]*$key"
comment='^[[:space:]]*#'

# A reference passes only in block style and only with one of these values: a
# local path, a docker image by digest, or owner/repo[/path] at a full commit
# SHA. The value may be in quotes and may be followed by a comment.
value="[.]/[^][:space:]\"',{}[]*"
value="$value|docker://[^][:space:]\"'@,{}[]+@sha256:[0-9a-f]{64}"
value="$value|[A-Za-z0-9_-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}"
pinned="${block}[[:space:]]+(($value)|\"($value)\"|'($value)')([[:space:]]+(#.*)?)?\$"

# A pattern that bash cannot compile matches nothing, so every file would
# pass. Prove that references are found before a clean result is trusted.
# (Newer versions of bash also print their own error for such a pattern.)
{ [[ '- uses: a/b@v1' =~ $reference ]] && [[ '- { uses: a/b@v1 }' =~ $reference ]]; } 2>/dev/null ||
  die 'the patterns do not work in this shell'

found=$(find -H "${dirs[@]}" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null) ||
  die 'could not list files'

files=0 references=0 failures=0
while IFS= read -r file; do
  [ -r "$file" ] || die "cannot read: $file"
  files=$((files + 1))
  number=0
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    line=${line%$'\r'} # CRLF files behave like LF files
    # GitHub Actions' YAML parser also treats NEL, LS and PS as line breaks.
    # Refuse any YAML line break that read did not split.
    [[ $line == *$'\r'* || $line == *$'\302\205'* || $line == *$'\342\200\250'* || $line == *$'\342\200\251'* ]] &&
      die "$file:$number: YAML line break inside a line (use LF or CRLF line endings)"
    if [[ $line =~ $reference ]] && ! [[ $line =~ $comment ]]; then
      references=$((references + 1))
      if ! [[ $line =~ $pinned ]]; then
        failures=$((failures + 1))
        trimmed=$(printf '%s\n' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        printf '%s:%s: not pinned to a full commit SHA: %s\n' "$file" "$number" "$trimmed"
      fi
    fi
  done < "$file"
done < <(if [ -n "$found" ]; then printf '%s\n' "$found" | sort; fi)

checked="files checked: $files, references checked: $references"
if [ "$failures" -gt 0 ]; then
  echo "check-action-pins: FAILED ($checked, not pinned: $failures)"
  echo 'Pin each one like this, on one line: uses: owner/repo@<40-character commit SHA> # v1.2.3'
  exit 1
fi
echo "check-action-pins: OK ($checked)"
