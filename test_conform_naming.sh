#!/usr/bin/env bash
#
# Checks for conform_naming.sh. Every case builds a throwaway tree under a temp
# directory and runs inside it, so nothing outside is touched. Run:
#
#   ./test_conform_naming.sh
#
# Exits nonzero if any check fails.
#
# How to read it. Each numbered case is: t (a fresh empty folder, cwd inside it), then
# printf/mkdir to build the situation, then one run of the script, then a line of
# checks. Every check prints one line -- "ok  <what it proves>" or "FAIL <what it
# proves>" with the reason under it. Nothing is written outside the temp folder, and the
# previous case's folder is deleted by the next t. So a full pass is ~150 ok lines and no
# FAIL lines; the names are written to be read on their own, because each one is a
# sentence about behaviour rather than about code.
#
# The helpers, since most of what is asserted goes through them:
#   quiet ARGS        run the script, discard its chatter -- for cases whose checks look
#                     at the folder afterwards, not at what was printed
#   out="$(...)"      run it and keep the output, for the checks below that read $out
#   check_yes/no NAME PATH     the path exists / is gone
#   check_says NAME PATH TEXT  the file holds exactly TEXT
#   check_match NAME OUT TEXT  OUT contains TEXT        check_nomatch the opposite
#   check_regex NAME OUT RE    OUT matches the regex
#   check_rc NAME RC WANT      the exit status was WANT
#
# Two habits in the case data are worth keeping. A clash has to be built on purpose --
# "a b.txt" wants a_b.txt, so an existing a_b.txt is a clash and an existing report.txt
# is not -- and a case that expects something to be removed must also prove it was the
# removal that happened, not a rename that merely left the folder looking the same.

set -uo pipefail
shopt -s nullglob          # so a glob with no match expands to nothing

S="$(cd "${0%/*}" && pwd)/conform_naming.sh"
[[ -f "$S" ]] || { printf 'cannot find %s\n' "$S" >&2; exit 1; }

pass=0
fail=0
T=""

ok()       { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()      { fail=$((fail + 1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }
exists()   { [[ -e "$1" || -L "$1" ]]; }

check_yes()    { exists "$2" && ok "$1" || bad "$1" "expected to exist: $2"; }
check_no()     { exists "$2" && bad "$1" "expected to be gone: $2" || ok "$1"; }
# Glob form: -e would not expand a pattern, so let the shell do it.
check_no_glob(){ local hits=($2); [[ ${#hits[@]} -eq 0 ]] && ok "$1" \
                 || bad "$1" "expected no $2, found ${hits[*]}"; }
check_says()   { [[ "$(cat "$2" 2>/dev/null)" == "$3" ]] && ok "$1" \
                 || bad "$1" "expected $(printf %q "$3") in $2, found $(printf %q "$(cat "$2" 2>/dev/null)")"; }
check_match()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "no $(printf %q "$3") in output: $(printf %q "$2")"; }
check_regex()  { [[ "$2" =~ $3 ]] && ok "$1" || bad "$1" "no match for $3 in: $(printf %q "$2")"; }
check_rc()     { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected exit $3, got $2"; }
check_nomatch(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "unexpected $(printf %q "$3") in output"; }
# Run the script when the checks look at the folder rather than at what it printed.
# Its own "renamed 1 entry / log: run.log" chatter between the ok lines made a run of
# this look like output of the tool rather than a report about it.
quiet()    { "$S" "$@" >/dev/null 2>&1 || true; }

# Fresh temp directory, cwd inside it. The previous one is discarded.
t() {
    if [[ -n "$T" ]]; then
        cd "${TMPDIR:-/tmp}" && rm -rf "$T"
    fi
    T="$(mktemp -d)" || exit 1
    cd "$T" || exit 1
}
trap 'cd "${TMPDIR:-/tmp}"; rm -rf "${T:-}"' EXIT

# 1. the basic rule
t
printf 'a\n' > "a file.txt"
quiet "a file.txt"
check_yes   "spaces become underscores" "a_file.txt"
check_no    "old name is gone"          "a file.txt"

# 2. accent folding, case kept
t
printf 'b\n' > "Café 2024.txt"
quiet -a "Café 2024.txt"
check_yes "accents fold, case kept" "Cafe_2024.txt"
check_no  "old name is gone"        "Café 2024.txt"

# --- the clash cases below need a clash built on purpose -----------------------
# "report copy.txt" wants report_copy.txt, which is nothing like the name report.txt
# holds, so those two never meet and no clash happens at all. A name holding a space
# and a name already holding the underscore it folds to are the pair that wants one
# target: "a b.txt" and a_b.txt both want a_b.txt.

# 3. without -k a clash is left alone, and nothing is overwritten
t
printf 'A\n' > a_b.txt
printf 'B\n' > "a b.txt"
out="$("$S" "a b.txt" 2>&1)"
check_match "clash reported as skipped"      "$out" "already exists"
check_says "clash leaves the target intact"  a_b.txt "A"
check_yes  "clash keeps the source"         "a b.txt"
check_no   "clash creates no numbered name" a_b_1.txt

# 4. -k with different content numbers the newcomer
t
printf 'A\n' > a_b.txt
printf 'B\n' > "a b.txt"
quiet -k --log run.log "a b.txt"
check_says "-k leaves the target alone"      a_b.txt    "A"
check_says "-k numbers the different bytes"  a_b_1.txt  "B"
check_no   "-k moved the source"             "a b.txt"
check_match "-k wrote the log" "$(cat run.log)" "a_b_1.txt"

# 5. -k with identical content keeps one copy
t
printf 'A\n' > a_b.txt
printf 'A\n' > "a b.txt"
out="$("$S" -k --log run.log "a b.txt" 2>&1)"
check_match "identical copy reported"    "$out"  "identical"
check_says "the kept file has the bytes" a_b.txt "A"
check_no    "the duplicate is gone"       "a b.txt"
check_no    "no numbered twin was made"   a_b_1.txt

# 6. a preview changes nothing and leaves no log behind
t
printf 'A\n' > a_b.txt
printf 'A\n' > "a b.txt"
out="$("$S" -n -k "a b.txt" 2>&1)"
check_match "preview says what it would do"   "$out" "would remove"
check_yes   "preview keeps the source"         "a b.txt"
check_no    "preview creates no numbered name" a_b_1.txt
check_no_glob "preview writes no log"          "conform_naming-*.log"

# 7. recursive, deepest first
t
mkdir -p "raw data/sub dir"
printf 'c\n' > "raw data/sub dir/a file.txt"
quiet -r .
check_yes "file renamed"       "raw_data/sub_dir/a_file.txt"
check_no  "folder renamed too" "raw data"

# 8. recursive with -a sees accented names too
t
mkdir -p "Příliš složka"
printf 'd\n' > "Příliš složka/žluťoučký kůň.txt"
quiet -r -a .
check_yes "deep accented file renamed" "Prilis_slozka/zlutoucky_kun.txt"
check_no  "accented folder renamed"    "Příliš složka"

# 9. a name still outside the rules is reported, not silently passed over
t
printf 'e\n' > "Café (2024).txt"
out="$("$S" -a "Café (2024).txt" 2>&1)"
check_yes "renamed as far as the table allows" "Cafe_(2024).txt"
check_match "the remainder is flagged" "$out" "still not naming-safe"

# 10. guards
t
out="$("$S" / 2>&1)"
check_match "root refused"      "$out" "refusing"
out="$("$S" --bogus x 2>&1)"
check_match "unknown option rejected" "$out" "unknown option"

# 11. the log records which bytes were declared identical
t
printf 'A\n' > a_b.txt
printf 'A\n' > "a b.txt"
quiet -k --log run.log "a b.txt"
check_regex "dedupe log line carries a checksum" "$(cat run.log)" 'identical [a-z0-9]+:'

# 12. undo puts a rename back
t
printf 'x\n' > "a file.txt"
quiet --log run.log "a file.txt"
check_yes "renamed first"  "a_file.txt"
quiet --undo run.log
check_yes  "the old name is back" "a file.txt"
check_no   "the new name is gone" "a_file.txt"
check_says "the bytes are intact" "a file.txt" "x"

# 13. undo recreates a name that was dropped as a duplicate. The clash has to be real
# here as well: with a non-clashing pair this case passed while only ever testing a
# rename, because "the duplicate was removed" and "the name came back" are also what a
# plain rename and its undo look like.
t
printf 'A\n' > a_b.txt
printf 'A\n' > "a b.txt"
quiet -k --log run.log "a b.txt"
check_no "the duplicate was removed first" "a b.txt"
quiet --undo run.log
check_yes  "the duplicate name is back"     "a b.txt"
check_says "its content is the same bytes"  "a b.txt" "A"
check_yes  "and the file it was identical to is intact" a_b.txt

# 14. undo refuses to displace a name something else has taken
t
printf 'x\n' > "a file.txt"
quiet --log run.log "a file.txt"
printf 'y\n' > "a file.txt"
out="$("$S" --undo run.log 2>&1)"
check_match  "undo reports the clash"     "$out" "already in use"
check_says   "the other file is untouched" "a file.txt" "y"
check_yes    "the renamed file is intact"   "a_file.txt"

# 15. undo is safe to run twice
t
printf 'x\n' > "a file.txt"
quiet --log run.log "a file.txt"
quiet --undo run.log
out="$("$S" --undo run.log 2>&1)"
check_match  "the second undo changes nothing" "$out" "already gone"
check_says   "still the same single file"      "a file.txt" "x"
check_no     "no second copy appeared"         "a_file.txt"

# 16. an undo preview touches nothing and logs nothing
t
printf 'x\n' > "a file.txt"
quiet --log run.log "a file.txt"
out="$("$S" -n --undo run.log 2>&1)"
check_yes     "preview leaves the rename in place" "a_file.txt"
check_no_glob "preview writes no log"              "conform_naming-*.log"

# 17. --undo takes a log, not paths
t
out="$("$S" --undo whatever.log . 2>&1)"
check_match "paths rejected" "$out" "takes no PATH"

# 18. a run must finish the whole argument list, not stop at the first entry that
# renames cleanly. This is the regression for the run that died halfway through:
# the clash sets the variable the plain-rename path only reads, so the plain one
# has to come after it for the bug to show at all.
t
printf 'A\n' > a_b.txt
printf 'B\n' > "a b.txt"
printf 'C\n' > "clean name.txt"
quiet -k --log run.log "a b.txt" "clean name.txt"
check_yes  "the clash was numbered"          a_b_1.txt
check_yes  "the later clean rename happened" clean_name.txt
check_no   "nothing was left with a space"   "clean name.txt"

# 19. and the same through a recursive walk: every entry has to be reached
t
mkdir -p "a dir"
printf '1\n' > "a dir/one.txt"
printf '2\n' > "a dir/two.txt"
quiet -r .
check_yes "a file inside was renamed" "a_dir/one.txt"
check_yes "the other file came along" "a_dir/two.txt"
check_no  "the folder itself too"     "a dir"

# 20. what did not move is recorded with its reason
t
printf 'A\n' > a_b.txt
printf 'B\n' > "a b.txt"
quiet --log run.log "a b.txt" "no such file.txt"
check_regex "the clash is recorded"         "$(cat run.log)" 'skipped.*target already exists'
check_regex "the missing path is recorded"  "$(cat run.log)" 'skipped.*no such file'

# 21. a name the fold table cannot finish is recorded, and undo walks past both
# kinds of report line without treating them as work to reverse
t
printf 'C\n' > "Café (2024).txt"
quiet -a --log run.log "Café (2024).txt"
check_regex "the unfinished name is recorded" "$(cat run.log)" 'note.*left as is'
out="$("$S" --undo run.log 2>&1)"
check_nomatch "undo is quiet about report lines" "$out" "unknown action"
check_yes     "and it still reversed the rename"  "Café (2024).txt"
check_no      "leaving nothing at the new name"   "Cafe_(2024).txt"

# 22. two files wanting one name and holding the same bytes: both stay, one record,
# and that record must not stop an undo from walking the log. Two distinct names that
# fold onto one target is what "folding can create a clash" means. Both accents have to
# sit in the same place in the stem: à and á both fold to a, so càfe.txt and cáfe.txt
# both want cafe.txt. cafeé.txt would not do -- its accent is at the end, so it folds to
# cafee.txt and never meets the name it was supposed to clash with.
t
printf 'incumbent\n' > cafe.txt
printf 'same\n' > "càfe.txt"
printf 'same\n' > "cáfe.txt"
out="$("$S" -a -k --log run.log "càfe.txt" "cáfe.txt" 2>&1)"
check_yes   "the first was numbered"          cafe_1.txt
check_yes   "the identical second was kept"   cafe_2.txt
check_says  "the incumbent was left alone"    cafe.txt   "incumbent"
check_regex "the duplicate is recorded"       "$(cat run.log)" 'duplicate.*same bytes as .*cafe_1.txt'
check_match "and said out loud"               "$out" "duplicate kept"
out="$("$S" --undo run.log 2>&1)"
check_nomatch "undo is quiet about the duplicate record" "$out" "unknown action"
check_yes  "undo brought the first name back" "càfe.txt"
check_yes  "and the second name back"         "cáfe.txt"
check_no   "leaving no numbered names"        cafe_1.txt

# 23. the audit: same bytes under different names in one folder, and nothing else
t
printf 'same\n'  > "a file.txt"
printf 'same\n'  > afile.txt
printf 'other\n' > unique.txt
mkdir -p sub
printf 'same\n' > sub/afile.txt
out="$("$S" -d -r . 2>&1)"; rc=$?
check_match   "the pair in one folder is found"   "$out" "duplicate group"
check_match   "both of its names are listed"      "$out" "a file.txt"
check_nomatch "a folder of its own is not merged" "$out" "sub/afile.txt"
check_nomatch "a unique file is not reported"     "$out" "unique.txt"
check_rc      "finding something exits 1"         "$rc" "1"

# 24. a clean folder says so and exits 0
t
printf 'one\n' > a.txt
printf 'two\n' > b.txt
out="$("$S" -d -r . 2>&1)"; rc=$?
check_match "a clean tree is said clean" "$out" "no duplicates"
check_rc    "and that is not a failure"  "$rc" "0"

# 25. two names on one inode are one file, not a duplicate
t
printf 'one\n' > only.txt
ln only.txt hardlink.txt
out="$("$S" -d -r . 2>&1)"; rc=$?
check_nomatch "links are not reported as duplicates" "$out" "duplicate group"
check_match   "they are counted aside instead"     "$out" "another link"
check_rc      "so the audit still passes"          "$rc" "0"

# 26. -d reports, so it refuses to be promised as -k
t
printf 'same\n' > a.txt
printf 'same\n' > "a copy.txt"
out="$("$S" -d -k . 2>&1)"; rc=$?
check_match "the combination is refused" "$out" "cannot be combined"
check_rc    "as a usage error"           "$rc" "2"
check_yes   "and nothing was renamed"    "a copy.txt"

# 27. the grouping must follow the path, not the order the files were made. This is
# the regression for a report that sorted its records by device and inode: one
# folder's files arrived scattered, each flush saw one file, and nothing was found
# except duplicates whose inode numbers happened to sit side by side.
t
printf 'same\n' > "keep 1.txt"
for i in $(seq 1 40); do printf 'x%s\n' "$i" > "filler $i.txt"; done
printf 'same\n' > "keep 2.txt"
for i in $(seq 1 40); do printf 'y%s\n' "$i" > "other $i.txt"; done
printf 'same\n' > "keep 3.txt"
out="$("$S" -d -r . 2>&1)"
check_match "all three identical files are one group" "$out" "x3"
check_match "the first is listed"                     "$out" "keep 1.txt"
check_match "the last is listed too"                  "$out" "keep 3.txt"
check_match "and the folder is reported once"         "$out" "1 duplicate group,"

# 28. a folder's own files are not contiguous in path order once it holds subfolders:
# one identical file on each side of a subfolder name still has to pair up. This is
# the regression for judging a folder as its path changes, which split ./.git into
# three runs and reported none of its duplicates.
t
printf 'same\n'   > m.txt
mkdir -p n_sub
printf 'filler\n' > n_sub/inside.txt
printf 'same\n'   > z.txt
out="$("$S" -d -r . 2>&1)"
check_match "the pair is found across the subfolder" "$out" "x2"
check_match "the file before it is listed"           "$out" "m.txt"
check_match "and the file after it"                  "$out" "z.txt"
check_nomatch "and the report says nothing is broken" "$out" "incomplete"

# 29. -c collapses a group: the name already spelled to the rules survives, the
# spaced twin is removed, and the removal is on record as deduped.
t
printf 'same\n'  > report.txt
printf 'same\n'  > "report copy.txt"
printf 'other\n' > unique.txt
out="$("$S" -d -c --log run.log . 2>&1)"; rc=$?
check_yes   "the conforming name was kept"  report.txt
check_no    "the spaced twin is gone"       "report copy.txt"
check_says  "the kept file holds the bytes" report.txt "same"
check_yes   "an unequal file was untouched" unique.txt
check_regex "the removal is logged"         "$(cat run.log)" 'deduped.*report copy.txt.*report.txt'
check_rc    "nothing left, so it passes"    "$rc" "0"
out="$("$S" -d -r . 2>&1)"; rc=$?
check_match "and the audit now comes back clean" "$out" "no duplicates"
check_rc    "clean, so exit 0"                   "$rc" "0"

# 30. the preview of a collapse takes nothing away and leaves no log behind -- and
# must not report success for work it did not do
t
printf 'same\n' > a.txt
printf 'same\n' > "a copy.txt"
out="$("$S" -d -c -n . 2>&1)"; rc=$?
check_match "the preview names the file"       "$out" "would remove"
check_match "and says which one stays"         "$out" "keeping"
check_yes   "both files are still there"       "a copy.txt"
check_no_glob "a preview writes no log"         "conform_naming-*.log"
check_rc    "and the group still stands, so 1" "$rc"   "1"

# 31. -c has to be pointed at something, and cannot double as an undo
t
out="$("$S" -c . 2>&1)"; rc=$?
check_match "-c alone is refused" "$out" "give it -d"
check_rc    "as a usage error"    "$rc"  "2"
out="$("$S" -c --undo run.log 2>&1)"; rc=$?
check_match "-c and --undo are separate actions" "$out" "two different actions"
check_rc    "as a usage error"                   "$rc"  "2"

# 32. with -k the sweep comes first, so an identical pair never reaches the clash
# that would otherwise have numbered one of them
t
printf 'A\n' > report.txt
printf 'A\n' > "report copy.txt"
printf 'B\n' > "other thing.txt"
out="$("$S" -r -k -c --log run.log . 2>&1)"; rc=$?
check_no   "the identical twin never needed a number" report_1.txt
check_no   "the duplicate is gone"                    "report copy.txt"
check_says "the kept copy has its bytes"              report.txt "A"
check_yes  "and the plain rename still happened"      other_thing.txt
check_regex "both kinds of work are in the log"       "$(cat run.log)" 'renamed.*other thing.txt'
check_regex "the collapse is in the log too"          "$(cat run.log)" 'deduped.*report copy.txt'

# 33. --undo brings a collapsed name back, as a link to the copy that was kept
t
printf 'A\n' > report.txt
printf 'A\n' > "report copy.txt"
quiet -d -c --log run.log .
check_no "collapsed first" "report copy.txt"
quiet --undo run.log
check_yes  "the removed name is back" "report copy.txt"
check_says "with the same bytes"      "report copy.txt" "A"
if [[ "report copy.txt" -ef report.txt ]]; then
    ok "and it is a link to the kept file, not a copy"
else
    bad "and it is a link to the kept file, not a copy" "expected the same inode"
fi

# 34. empty files are reported and left alone: nothing to reclaim, and an empty file
# is usually a deliberate placeholder
t
: > "empty one.txt"
: > empty_two.txt
out="$("$S" -d -c --log run.log . 2>&1)"; rc=$?
check_match "the empty pair is reported"      "$out" "empty, left alone"
check_yes   "one is still there"              "empty one.txt"
check_yes   "and so is the other"             empty_two.txt
check_rc    "so the run does not claim done"  "$rc"  "1"

# 35. .git is never entered. A repository holds duplicates of its own, and renaming
# or unlinking inside it breaks the repository in silence
t
mkdir -p .git/hooks data
printf 'same\n' > .git/hooks/a.sample
printf 'same\n' > .git/hooks/b.sample
printf 'same\n' > data/a.txt
printf 'same\n' > "data/b b.txt"
out="$("$S" -d -r . 2>&1)"
check_nomatch "the copies inside .git are not reported" "$out" ".git"
check_match   "the real pair still is"                  "$out" "data"
quiet -r .
check_yes "a spaced name inside .git keeps its name" ".git/hooks/b.sample"
check_yes "while the data folder was tidied"         "data/b_b.txt"

# 36. a preview must plan one fate per file. Under -n nothing is really removed, so
# the rename pass used to plan renames for files the run then deletes -- a plan that
# cannot happen, which is what the user saw as "removed" beside "->".
t
printf 'same\n'  > "keep one.txt"
printf 'same\n'  > "keep two.txt"
printf 'other\n' > "other thing.txt"
out="$("$S" -r -a -k -c -n . 2>&1)"
check_match   "the removal is planned"                "$out" "would remove ./keep two.txt"
check_nomatch "no rename is planned for it as well"   "$out" "keep two.txt ->"
check_match   "the copy that survives is renamed"     "$out" "keep one.txt -> ./keep_one.txt"
check_match   "and an unrelated rename still shows"   "$out" "other thing.txt -> ./other_thing.txt"

# 37. `-r .` is the documented way to tidy the current folder. With -a there is no
# -name filter, so find listed the starting point itself and the run ended with
# "has no name to rename" and a false skipped count, on its own recommended command.
t
mkdir -p "a dir"
printf 'q\n' > "a dir/x.txt"
out="$("$S" -r -a . 2>&1)"
check_nomatch "the starting point is not an entry" "$out" "no name to rename"
check_nomatch "and nothing counts as skipped"      "$out" "skipped"
check_yes     "the contents were renamed"          "a_dir/x.txt"

# 38. the survivor is the copy nearest the rules, not merely one that shares a defect
# with the rest: one space beats two accents, even though the accented name is the
# shorter of the two, which is what a conforms-or-does-not test would have compared.
t
printf 'same\n' > "spaced name.txt"
printf 'same\n' > "éõ.txt"
out="$("$S" -d -c -n . 2>&1)"
check_match "the name with one space is kept"        "$out" "keeping ./spaced name.txt"
check_match "and the accented twin is the one to go" "$out" "would remove ./éõ.txt"

# 39. -v has to echo the removals as well as the moves. run() is what prints the
# command, and a preview never reaches it, so a verbose preview listed every mv of
# the run and not one rm -- the removals were the invisible half of the plan.
t
printf 'same\n' > a.txt
printf 'same\n' > "a copy.txt"
out="$("$S" -d -c -n -v . 2>&1)"
check_regex "the removal is echoed as a command" "$out" '\+ rm -- \./a'
# the summary is allowed to say "would remove 1 duplicate" -- what must not appear is
# the per-file prose line beside the command line that already says it
check_nomatch "and no second line per removal"      "$out" "        would remove"
out="$("$S" -d -c -n . 2>&1)"
check_match "without -v the preview says it in words" "$out" "would remove ./a copy.txt"
check_nomatch "and echoes no command"                 "$out" "+ rm"

# 40. nothing hidden is entered, renamed, compared or removed. A name starting with a
# dot says the thing belongs to a program or to the user, not to the data being tidied
# -- and under -c the difference is a file that survives.
t
mkdir -p ".config/app dir" .cache
printf 'q\n'     > ".config/app dir/a file.txt"
printf 'same\n'  > ".hidden one.txt"
printf 'same\n'  > ".hidden two.txt"
printf 'same\n'  > "visible one.txt"
printf 'same\n'  > "visible two.txt"
out="$("$S" -r -a -d -c -n . 2>&1)"
check_match   "a visible pair is still found"           "$out" "visible two.txt"
check_nomatch "a hidden pair is not"                    "$out" "hidden"
check_nomatch "nor is anything inside a hidden folder"  "$out" "app dir"
quiet -r .
check_yes "the hidden folder and its contents keep their names" ".config/app dir/a file.txt"
check_yes "both hidden files are still there"                   ".hidden two.txt"
check_yes "while the visible pair was renamed"                  "visible_one.txt"
quiet ".hidden one.txt"
check_yes "a hidden name typed by hand is still renamed"        ".hidden_one.txt"

# 41. both find expressions have to parse. A syntax error there does not look like a
# failure: find walks nothing, the script finds nothing to do, and the run ends with
# exit 0 and "nothing removed" while renaming and reporting nothing at all.
t
mkdir -p "d 1/sub"
printf 'same\n' > "d 1/a b.txt"
printf 'same\n' > "d 1/c d.txt"
printf 'x\n'    > "d 1/sub/e f.txt"
out="$("$S" -r -a -k -c -n -v . 2>&1)"; rc=$?
check_nomatch "no walk complained about its expression" "$out" "expected an expression"
check_match   "the audit walk ran and found the pair"   "$out" "+ rm --"
check_match   "the rename walk ran too"                 "$out" "+ mv --"
check_rc      "and the preview ends cleanly"            "$rc" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
