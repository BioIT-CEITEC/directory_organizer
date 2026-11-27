#!/usr/bin/env bash
#
# Rename a file or folder by replacing the spaces in its name with underscores,
# and, with -a, by folding accented Latin letters to plain ASCII.
# Only the last component of the path is renamed; the parent path is left alone.
#
# Requires bash 4.4+ (local associative arrays, empty arrays under set -u) and GNU
# findutils/coreutils (find -print0, -printf, sort -z). Only the literal space
# character is replaced -- tabs, newlines and other whitespace are left untouched.

set -euo pipefail

INVOCATION="$*"                # recorded in the log header, before the options go away

DRY_RUN=false
RECURSIVE=false
VERBOSE=false
FOLD_ACCENTS=false
KEEP_BOTH=false
AUDIT=false
COLLAPSE=false
LOG_FILE=""
UNDO_FILE=""
RUN_STAMP=""
renamed=0
skipped=0
notes=0
deduped=0
duplicates=0
undone=0
restored=0

# Set by numbered_target when some file in the numbered family already holds the
# very bytes being placed, and the digest that proved it.
DUP_SIBLING=""
DUP_SUM=""

# Audit totals, and the files of the one folder being audited at a time.
hardlinked=0
audit_groups=0
audit_extra=0
audit_bytes=0
audit_left=0
a_dir=""
a_names=()
a_sizes=()
a_devino=()

# Checksum tool and the digests of the last files_identical call, kept for the log.
SUM_TOOL=""
SUM_LABEL=""
SUM_FROM=""
SUM_TARGET=""

# Names this run has claimed. A dry run renames nothing, so without this it would
# hand the same numbered name to two different files.
declare -A PLANNED=()
# Paths -c has judged redundant and removed, or in a preview is about to remove. The
# rename pass must not also plan work on them: a real run would never see them again.
declare -A COLLAPSED=()

usage() {
    cat <<'EOF'
Usage: conform_naming.sh [options] PATH [PATH ...]

Rename every PATH to conform to the usual naming rules: spaces become underscores,
with -a accented Latin letters fold to ASCII, and with -k a name clash keeps both
files instead of skipping one. With -d nothing is renamed: the folders are audited
for files holding identical bytes under different names.

Options:
  -n, --dry-run    Print what would change, rename nothing.
  -r, --recursive  Also rename everything inside each PATH (deepest first).
  -a, --ascii      Also fold accented Latin letters to plain ASCII:
                   é -> e, ř -> r, ß -> ss, æ -> ae. Case is preserved.
  -k, --keep-both  Resolve a clash instead of skipping it:
                     same bytes already there  -> one copy kept, the redundant
                                                 source is removed and logged
                     different bytes           -> stem_1.ext, stem_2.ext, ...
                   Two files that wanted the same name and hold the same bytes as
                   an already-numbered sibling are both kept and recorded as a
                   duplicate line -- that call stays yours.
                   Always preview with -n first. Writes a log, see --log.
  -d, --duplicate  Report files holding identical bytes inside the same folder,
                   whatever they are called. On its own it reports only: nothing is
                   renamed or removed and no log is written, but the exit status is
                   1 when any are found, so it can gate a pipeline. Add -r to
                   descend, one folder at a time. Add -c to remove them.
  -c, --collapse   Remove the duplicates -d finds, keeping one copy of each. With
                   -k instead, the sweep happens before any renaming, so the name
                   clashes left are between files that differ. With -n nothing is
                   removed and nothing is logged: preview it first, always.
                     which name survives  the one nearest the rules: fewest
                                        characters that would have to change (a
                                        space, an accent), then the shorter name,
                                        then the order the folder listed them in
                     what is kept         the file itself is never rewritten, only
                                        its twins unlinked, so no bytes are copied
                     empty files          reported and left alone; nothing to
                                        reclaim, and an empty file is often a
                                        deliberate placeholder
                     hidden entries       nothing whose name starts with a dot is
                                        entered, renamed, compared or removed --
                                        .git, .cache, .config, .bashrc, ".hidden
                                        data.txt" all left alone. A hidden name
                                        typed by hand is still honoured, since a
                                        walk falling on one and you asking for it
                                        are two different things
                   Every removal is logged as deduped, so --undo brings the name
                   back as a link to the copy kept. Needs -d or -k.
      --log FILE   Append every action to FILE. Without it -k and -c log to
                   conform_naming-<timestamp>.log in the current directory. The
                   log must be writable before anything is renamed or removed.
      --undo LOG   Reverse a logged run instead of renaming anything: renames are
                   moved back, and a name dropped as a duplicate is recreated as a
                   link to the copy that was kept. Takes the log in place of PATHs.
                   Newest action first, refuses to overwrite, so a second run of
                   the same undo does nothing further. Preview it with -n. Run it
                   from the directory the logged run was started in: the log holds
                   the paths as they were given, not absolute ones.
  -v, --verbose    Echo the find and mv commands as they run, shell-quoted.
                   With -n they are shown without being executed.
  -h, --help       Show this help and exit.

Examples:
  conform_naming.sh "raw data"             raw data -> raw_data
  conform_naming.sh -n "IMG 2024 01.jpg"   preview only, nothing is moved
  conform_naming.sh -r "project one"       contents first, then the folder itself
  conform_naming.sh -a "Café 2024"         Cafe_2024
  conform_naming.sh -r -n .                preview every spaced name under cwd
  conform_naming.sh -r -n -v .             show the exact commands a real run uses
  conform_naming.sh -r -n -a .             the same, plus accented names
  conform_naming.sh -r -n -a -k .          the same, resolving clashes too
  conform_naming.sh --undo conform_naming-20261127T091402.log

Without -r only the name itself is renamed, so "." and ".." do nothing.
The filesystem root is always refused. Nothing whose name starts with a dot is
entered, renamed, compared or removed -- type such a name yourself if you mean
it. Entries are handled in sorted order, so the same folder gives the same
result twice.

A clash is skipped with a warning unless -k is given; nothing is ever overwritten.
Only clashes are checksummed, not plain renames -- reading a 200 GB file to
annotate its rename costs far more than the rename. A name holding a tab or a
newline is reported and left out of the log, so --undo cannot cover that one.
EOF
}

# Latin letters folded to plain ASCII: one line per target letter. Edit the
# table here if a name should read differently (ø -> oe rather than o, say).
# Anything outside Latin -- Greek, Cyrillic, CJK -- is deliberately not here.
# Keys are matched literally by ${name/key/value}, so keep them to single
# letters without glob characters (* ? [ ]).
FOLD_PAIRS=()
_fold() {
    local to="$1" letter
    shift
    for letter in "$@"; do               # each remaining argument is one letter
        FOLD_PAIRS+=("$letter=$to")
    done
}
_fold a  à á â ã ä å ā ă ą ǎ ȁ ạ
_fold A  À Á Â Ã Ä Å Ā Ă Ą Ǎ
_fold c  ç ć ĉ č
_fold C  Ç Ć Ĉ Č
_fold d  ď đ ð
_fold D  Ď Đ Ð
_fold e  è é ê ë ĕ ě ē ė ę
_fold E  È É Ê Ë Ě Ē Ė Ę
_fold g  ĝ ģ ğ ǵ
_fold G  Ĝ Ģ Ğ Ǵ
_fold h  ĥ
_fold H  Ĥ
_fold i  ì í î ï ĩ ī ĭ į ı
_fold I  Ì Í Î Ï Ī Ĭ Į İ
_fold j  ĵ
_fold J  Ĵ
_fold k  ķ
_fold K  Ķ
_fold l  ĺ ļ ľ ł
_fold L  Ĺ Ľ Ł
_fold n  ñ ń ň ņ ŋ
_fold N  Ñ Ń Ň Ņ
_fold o  ò ó ô õ ö ø ō ŏ ő
_fold O  Ò Ó Ô Õ Ö Ø Ō Ő
_fold r  ŕ ř ŗ
_fold R  Ŕ Ř Ŗ
_fold s  ś ŝ ş š ș
_fold S  Ś Ŝ Ş Š Ș
_fold t  ť ţ ț ŧ
_fold T  Ť Ţ Ț Ŧ
_fold u  ù ú û ü ũ ū ŭ ů ű ų
_fold U  Ù Ú Û Ü Ũ Ū Ŭ Ů Ű Ų
_fold w  ŵ
_fold W  Ŵ
_fold y  ý ÿ ỳ
_fold Y  Ý Ÿ
_fold z  ź ż ž
_fold Z  Ź Ż Ž
_fold ae æ
_fold AE Æ
_fold oe œ
_fold OE Œ
_fold ss ß
_fold th þ
_fold TH Þ

# Fold $1 to plain ASCII and leave the result in FOLDED. Deliberately not
# iconv -t ASCII//TRANSLIT: glibc, musl and busybox each transliterate
# differently, so the same name would come out differently on two machines.
fold_accents() {
    local pair
    FOLDED="$1"
    for pair in "${FOLD_PAIRS[@]}"; do
        FOLDED="${FOLDED//${pair%=*}/${pair#*=}}"
    done
}

# Print a command in shell-quoted form. Note %q leaves glob characters bare, so
# a pasted find line may glob before running; the mv lines are exact.
print_cmd() {
    local line='+' arg
    for arg in "$@"; do
        line+=" $(printf '%q' "$arg")"
    done
    printf '%s\n' "$line"
}

# Run a command, echoing it first when verbose. Under --dry-run the command is
# echoed or summarised but never executed.
run() {
    if $VERBOSE; then
        print_cmd "$@"
    fi
    if $DRY_RUN; then
        return 0
    fi
    "$@"
}

# Parent + name, avoiding the double slash that "/" would otherwise produce.
join_path() {
    if [[ "$1" == "/" ]]; then
        printf '/%s' "$2"
    else
        printf '%s/%s' "$1" "$2"
    fi
}

# Can this name not be used? Both real entries and names already claimed by this
# run count.
name_taken() {
    [[ -e "$1" || -L "$1" || -n "${PLANNED["$1"]+x}" ]]
}

# Digest of $1 as <algo>:<value> on stdout; nonzero when no checksum tool exists.
# Read via stdin so the file name never becomes part of the output. The tool is
# remembered, because two files must be measured the same way to be comparable.
file_sum() {
    if [[ -z "$SUM_TOOL" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
            SUM_TOOL=sha256sum
            SUM_LABEL=sha256
        elif command -v cksum >/dev/null 2>&1; then
            SUM_TOOL=cksum               # CRC32: weaker, but only pairs are compared
            SUM_LABEL=cksum
        else
            return 1
        fi
    fi
    if [[ "$SUM_TOOL" == sha256sum ]]; then
        printf '%s:%s' "$SUM_LABEL" "$(sha256sum < "$1" | cut -d' ' -f1)"
    else
        printf '%s:%s' "$SUM_LABEL" "$(cksum < "$1" | tr -s ' ' ':' | cut -d: -f1,2)"
    fi
}

# True when both paths are regular files holding the same bytes. Size is checked
# first so a mismatch settles it without reading two large files. Leaves both
# digests in SUM_FROM and SUM_TARGET for the log, empty when size settled it.
files_identical() {
    local a="$1" b="$2"
    SUM_FROM=""
    SUM_TARGET=""
    [[ -f "$a" && -f "$b" ]] || return 1
    [[ "$(wc -c < "$a")" == "$(wc -c < "$b")" ]] || return 1
    SUM_FROM="$(file_sum "$a")" || return 1
    SUM_TARGET="$(file_sum "$b")" || return 1
    [[ -n "$SUM_FROM" && "$SUM_FROM" == "$SUM_TARGET" ]]
}

# First free numbered name in $1 for the name $2, keeping the extension:
# report.txt -> report_1.txt. Leaves it in JOINED. Gives up after 1000 tries
# rather than looping on a directory already full of numbered siblings.
#
# While walking the family it also compares $3 against each occupied sibling.
# Those siblings are exactly the files that wanted the same name, so an identical
# one is a duplicate worth reporting -- the only thing that made the walk worth more
# than a search for a gap. Nothing is removed on that account: DUP_SIBLING says so
# and the caller decides, which today means record it and keep both. Under -n the
# siblings this run would have created are not on disk yet, so only duplicates
# against files that exist already can be reported -- a preview may name fewer.
numbered_target() {
    local dir="$1" name="$2" source="$3" n
    local stem="" ext="" candidate="" joined=""
    DUP_SIBLING=""
    DUP_SUM=""
    if [[ "$name" == *.* && "$name" != .* ]]; then
        stem="${name%.*}"
        ext="${name##*.}"
    else
        stem="$name"
        ext=""
    fi
    for (( n = 1; n <= 1000; n++ )); do
        if [[ -n "$ext" ]]; then
            candidate="${stem}_${n}.${ext}"
        else
            candidate="${stem}_${n}"
        fi
        joined="$(join_path "$dir" "$candidate")"
        if name_taken "$joined"; then
            if [[ -z "$DUP_SIBLING" ]] && files_identical "$source" "$joined"; then
                DUP_SIBLING="$joined"
                DUP_SUM="$SUM_FROM"
            fi
            continue
        fi
        JOINED="$joined"
        return 0
    done
    printf 'conform_naming: no free numbered name in %s\n' "$dir" >&2
    return 1
}

# Append one action to the log. Only actions that really happened belong there:
# a failed mv must not leave a rename in the record that never took place, and a
# dry run writes nothing at all -- redirect its output to keep a preview.
log_action() {
    [[ -n "$LOG_FILE" ]] || return 0
    # Spelled as a command test, not inside [[ ]]: there, `! $DRY_RUN` negates the
    # *string* "false", which is non-empty and therefore true, so the condition
    # would be false every time and nothing would ever be logged.
    if $DRY_RUN; then
        return 0
    fi

    # --undo reads one path per tab-separated field, so a name holding a tab or a
    # newline cannot be recorded faithfully. Say so rather than write a line that
    # would be replayed wrong.
    if [[ "$2" == *[$'\t\n']* || "$3" == *[$'\t\n']* ]]; then
        printf 'conform_naming: not logged, %s holds a tab or newline, so --undo cannot cover it\n' "$2" >&2
        return 0
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$RUN_STAMP" "$1" "$2" "$3" "${4:-}" >> "$LOG_FILE"
}

# Two record types that report rather than change anything: why an entry did not
# move, and which names are still outside the rules. --undo passes over both, so
# the log can be a full account of a run without offering anything to replay.
log_skipped() { log_action skipped "$1" "$2" "$3"; }
log_note()    { log_action note "$1" "" "$2"; }

# Rename one path. Returns 0 always so that one bad entry cannot abort the run
# under `set -e`.
rename_path() {
    local path="$1"

    # Already judged redundant this run and removed -- or, under -n, about to be. In
    # a real run the file is gone before the walk is built, so this only ever bites
    # in a preview: without it the plan shown renames a file the run then deletes,
    # which is a plan that cannot happen.
    if [[ -n "${COLLAPSED["$path"]+x}" ]]; then
        return 0
    fi

    # Assigned further down, but given a value here: `local x` on its own leaves x
    # *unset*, and reading an unset name under set -u kills the whole shell rather
    # than just this entry -- which is how a run came to stop halfway through.
    local dir="" base="" new="" target="" intended="" sum_from="" sum_target=""
    DUP_SIBLING=""
    DUP_SUM=""

    # Drop trailing slashes so that "my dir/" and "my dir" behave identically.
    while [[ "${#path}" -gt 1 && "$path" == */ ]]; do
        path="${path%/}"
    done

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'conform_naming: not found: %s\n' "$path" >&2
        log_skipped "$path" "" "no such file or directory"
        skipped=$((skipped + 1))
        return 0
    fi

    # Split into parent + name. "my dir" contains no slash, so the expansion
    # leaves it unchanged and the parent is "."; "/my dir" gives an empty parent.
    dir="${path%/*}"
    if [[ "$dir" == "$path" ]]; then
        dir="."
    elif [[ -z "$dir" ]]; then
        dir="/"
    fi

    base="${path##*/}"
    new="${base// /_}"
    if $FOLD_ACCENTS; then
        fold_accents "$new"
        new="$FOLDED"
    fi

    # "." and ".." name a directory rather than a name to rewrite.
    if [[ "$base" == "." || "$base" == ".." ]]; then
        printf 'conform_naming: %s has no name to rename -- use -r to rename its contents\n' "$path" >&2
        skipped=$((skipped + 1))
        return 0
    fi

    if [[ "$base" == "$new" ]]; then
        return 0                           # nothing this script would change
    fi

    # -a exists to reach naming rules, so report names that are still short of
    # them: punctuation, or letters the fold table does not cover.
    if $FOLD_ACCENTS && [[ ! "$new" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        printf 'conform_naming: still not naming-safe: %s\n' "$new" >&2
        log_note "$new" "left as is, as far as the fold table could take it"
        notes=$((notes + 1))
    fi

    target="$(join_path "$dir" "$new")"

    if name_taken "$target"; then
        if ! $KEEP_BOTH; then
            printf 'conform_naming: target already exists, skipped: %s\n' "$target" >&2
            log_skipped "$path" "$target" "target already exists, rename it or use -k"
            skipped=$((skipped + 1))
            return 0
        fi

        if files_identical "$path" "$target"; then
            # The same bytes already sit at the target name, so keeping all of
            # them means keeping them once. Only the redundant source is removed
            # -- the file that was already there is never touched, so its inode,
            # timestamps and permissions stay as they were.
            if $DRY_RUN; then
                printf 'would remove %s, identical to %s\n' "$path" "$target"
            else
                printf 'removed %s, identical to %s\n' "$path" "$target"
            fi
            if ! run rm -- "$path"; then
                printf 'conform_naming: failed to remove duplicate: %s\n' "$path" >&2
                log_skipped "$path" "$target" "identical, but the duplicate could not be removed"
                skipped=$((skipped + 1))
                return 0
            fi
            log_action deduped "$path" "$target" "identical $SUM_FROM"
            deduped=$((deduped + 1))
            return 0
        fi

        # Different bytes: both stay, the newcomer gets a number. The digests that
        # settled it are saved first -- looking for a free name hashes against the
        # siblings too and would otherwise overwrite them.
        intended="$target"
        sum_from="$SUM_FROM"
        sum_target="$SUM_TARGET"
        if ! numbered_target "$dir" "$new" "$path"; then
            log_skipped "$path" "$target" "no free numbered name in $dir"
            skipped=$((skipped + 1))
            return 0
        fi
        printf 'clash, different content: %s -> %s\n' "$path" "$JOINED"
        if [[ -n "$DUP_SIBLING" ]]; then
            printf 'duplicate kept: %s holds the same bytes as %s\n' "$path" "$DUP_SIBLING"
            duplicates=$((duplicates + 1))
        fi
        target="$JOINED"
    fi

    # Without -v a dry run reads better as "old -> new" than as a mv command.
    if $DRY_RUN && ! $VERBOSE; then
        printf '%s -> %s\n' "$path" "$target"
    fi
    # Guarded so a refused mv (permissions, read-only mount) reports and carries
    # on, instead of set -e abandoning the rest of a half-finished run.
    if ! run mv -- "$path" "$target"; then
        printf 'conform_naming: failed: %s -> %s\n' "$path" "$target" >&2
        log_skipped "$path" "$target" "mv was refused"
        skipped=$((skipped + 1))
        return 0
    fi
    renamed=$((renamed + 1))
    PLANNED["$target"]=1                 # reserved for the rest of this run
    if [[ -n "$intended" ]]; then
        # Both digests are already known -- they are what decided the clash -- so
        # recording them costs nothing. Plain renames are deliberately not hashed:
        # reading a 200 GB file to annotate its rename costs far more than the
        # rename itself.
        local note="numbered instead of $intended"
        if [[ -n "$sum_from" ]]; then
            note+="; $sum_from vs $sum_target"
        fi
        log_action renamed "$path" "$target" "$note"
    else
        log_action renamed "$path" "$target"
    fi
    # Kept rather than removed: two files with the same bytes that wanted the same
    # name are a call for whoever knows what they hold, so this only records it.
    if [[ -n "$intended" && -n "$DUP_SIBLING" ]]; then
        log_action duplicate "$path" "$target" "same bytes as $DUP_SIBLING, both kept $DUP_SUM"
    fi
}

# Rename everything under a path, deepest entries first so that the recorded
# paths of the remaining entries stay valid while we work upwards.
rename_recursive() {
    local root="$1"
    local paths=() path

    if [[ ! -e "$root" && ! -L "$root" ]]; then
        printf 'conform_naming: not found: %s\n' "$root" >&2
        log_skipped "$root" "" "no such file or directory"
        skipped=$((skipped + 1))
        return 0
    fi

    # Collect the full list before touching anything: renaming entries while
    # find is still reading a directory can make it revisit or miss entries.
    # -name must precede -print0 in the expression, or find prints everything.
    # With -a the rule depends on the fold table, which find cannot express, so
    # every entry is listed and each name is judged in rename_path instead.
    # Nothing hidden is entered or renamed: not .git -- renaming a loose object, a
    # ref or a packed copy breaks a repository in silence, the worst kind of failure
    # here -- nor .config, .cache, .bashrc or anything else whose name says it belongs
    # to a program or to you rather than to the data being tidied.
    #
    # -mindepth 1 keeps the starting point out of the list, which is what lets the
    # whole rule be one -prune: without it, "." would itself match -name '.*' and
    # prune the run away. It also means -depth is gone, and -prune needs exactly that
    # (it does nothing under -depth, where find has descended before judging the
    # directory). Order does not depend on it: the list is sorted deepest-first below,
    # and collected in full before anything is renamed.
    local find_args=("$root" -mindepth 1)
    # Both prune tests live in one group, and the -o that separates that group from
    # the printing branch goes AFTER the closing parenthesis. Leftover -o inside the
    # group is a syntax error find refuses to run at all -- "expected an expression
    # between '-o' and ')'" -- which is the good outcome: the alternative is a walk
    # that quietly listed everything the group was there to keep out.
    find_args+=(\( -name .git -type d -prune -o -name '.*' -prune \) -o)
    if ! $FOLD_ACCENTS; then
        find_args+=(-name '* *')
    fi
    find_args+=(-print0)

    if $VERBOSE; then
        print_cmd find "${find_args[@]}"
    fi
    # Handled in sorted order, so the same folder gives the same result twice --
    # that matters as soon as -k is choosing names. Descending, because a
    # descendant path always sorts after its ancestor: reversed, children are
    # renamed before the folders holding them, so recorded paths stay valid.
    while IFS= read -r -d '' path; do
        paths+=("$path")
    done < <(find "${find_args[@]}" | LC_ALL=C sort -z -r)

    for path in "${paths[@]}"; do
        rename_path "$path"
    done

    # The starting point is renamed last, after everything it holds. It is not in the
    # list above because -mindepth 1 leaves it out: it is not something the walk came
    # across, it is what the user named, so it is renamed even when the walk found
    # nothing. "." and "./" name where they are standing rather than a name to
    # rewrite, and are passed over quietly -- handing "." to rename_path used to end
    # every `-r .` run with "has no name to rename" and a false `skipped 1`, on the
    # very command this script's own help recommends.
    case "${root%/}" in
        ''|.|..) ;;
        *) rename_path "$root" ;;
    esac
}

# Bytes as a short string. The audit report is meant to be read, not parsed.
human_bytes() {
    local b="$1"
    if (( b >= 1073741824 )); then
        printf '%d.%d GB' "$(( b / 1073741824 ))" "$(( b % 1073741824 * 10 / 1073741824 ))"
    elif (( b >= 1048576 )); then
        printf '%d.%d MB' "$(( b / 1048576 ))" "$(( b % 1048576 * 10 / 1048576 ))"
    elif (( b >= 1024 )); then
        printf '%d.%d kB' "$(( b / 1024 ))" "$(( b % 1024 * 10 / 1024 ))"
    else
        printf '%d B' "$b"
    fi
}

# Report the files collected in a_dir that hold the same bytes, whatever they are
# called. Two gates keep the reading down: a file whose size is unique in the
# folder cannot have a twin and is never opened, and two names on one inode are one
# file rather than a duplicate -- which matters because --undo recreates a removed
# duplicate as a link, and a naive report would call that a duplicate.
flush_dir() {
    local i j key n=${#a_names[@]}
    local -A first_of=() size_count=() dig=() dcount=() dsize=() dfirst=()
    local -a cand=()
    local groups=0 extra=0 bytes=0
    local keep="" keep_len=0 keep_nlen=0 rank="" len=0 nlen=0 fname=""

    if (( n >= 2 )); then
        for (( i = 0; i < n; i++ )); do
            key="${a_devino[i]}"
            if [[ -n "${first_of[$key]+x}" ]]; then
                hardlinked=$((hardlinked + 1))
            else
                first_of["$key"]="$i"
                size_count["${a_sizes[i]}"]=$(( ${size_count["${a_sizes[i]}"]:-0} + 1 ))
            fi
        done
        for (( i = 0; i < n; i++ )); do
            [[ "${first_of["${a_devino[i]}"]:-none}" == "$i" ]] || continue
            (( ${size_count["${a_sizes[i]}"]:-0} >= 2 )) || continue
            cand+=("$i")
        done
    fi

    for i in "${cand[@]}"; do
        if ! key="$(file_sum "${a_names[i]}")" || [[ -z "$key" ]]; then
            # An unreadable file must not collapse onto the others through an
            # empty digest, which is what a failed checksum leaves behind.
            printf 'conform_naming: cannot read for comparison: %s\n' "$a_names[i]" >&2
            continue
        fi
        dig["$i"]="$key"
        if [[ -n "${dcount[$key]+x}" ]]; then
            dcount["$key"]=$(( dcount["$key"] + 1 ))
        else
            dcount["$key"]=1
            dsize["$key"]="${a_sizes[i]}"
            dfirst["$key"]="$i"
        fi
    done

    for key in "${!dcount[@]}"; do
        (( dcount["$key"] >= 2 )) || continue
        groups=$((groups + 1))
        extra=$(( extra + dcount["$key"] - 1 ))
        bytes=$(( bytes + dsize["$key"] * (dcount["$key"] - 1) ))
    done
    if (( groups == 0 )); then
        return 0
    fi

    printf '%s: %d duplicate group%s, %d extra cop%s, %s reclaimable\n' \
        "$a_dir" "$groups" "$([[ $groups -eq 1 ]] && echo '' || echo s)" \
        "$extra" "$([[ $extra -eq 1 ]] && echo y || echo ies)" "$(human_bytes "$bytes")"
    # Without -c the report is the whole answer, so every group still stands.
    if ! $COLLAPSE; then
        audit_left=$((audit_left + groups))
    fi

    for i in "${cand[@]}"; do
        key="${dig[$i]}"
        [[ "${dfirst[$key]}" == "$i" ]] || continue

        if ! $COLLAPSE; then
            printf '    %s  %s  x%d\n' "${key:0:24}" "$(human_bytes "${dsize[$key]}")" "${dcount[$key]}"
            for (( j = 0; j < n; j++ )); do
                if [[ "${dig[$j]:-}" == "$key" ]]; then
                    printf '        %s\n' "${a_names[j]}"
                fi
            done
            continue
        fi

        # Which name survives: the one nearest the naming rules. Deleting the safe
        # characters from the name leaves only the ones that would have to change --
        # a space, an accent -- so the length of the remainder counts how far that
        # name still is from conforming. Fewer of them wins, then the shorter name,
        # then the order the folder listed them in. Deciding it this way means the
        # copy that needs least work survives rather than whichever sorts first: a
        # binary "conforms or does not" test ranks two bad names equal and lets the
        # filesystem choose, which is how a run came to keep `tésto_file 1.txt` over
        # `test__file_1.txt`. The kept file is never rewritten -- only its twins
        # are unlinked.
        keep=""
        keep_len=0
        keep_nlen=0
        for (( j = 0; j < n; j++ )); do
            [[ "${dig[$j]:-}" == "$key" ]] || continue
            fname="${a_names[j]##*/}"
            rank="${fname//[A-Za-z0-9._+-]/}"
            len=${#rank}
            nlen=${#fname}
            if [[ -z "$keep" ]] || (( len < keep_len )) \
                || { (( len == keep_len )) && (( nlen < keep_nlen )); }; then
                keep="$j"
                keep_len="$len"
                keep_nlen="$nlen"
            fi
        done

        # Nothing to reclaim in an empty file, and an empty file is often a
        # deliberate placeholder: report it, leave it alone.
        if (( dsize["$key"] == 0 )); then
            printf '    %s  x%d  empty, left alone\n' "${key:0:24}" "${dcount[$key]}"
            audit_left=$((audit_left + 1))
            continue
        fi

        printf '    %s  %s  x%d  keeping %s\n' "${key:0:24}" "$(human_bytes "${dsize[$key]}")" \
            "${dcount[$key]}" "${a_names[keep]}"
        # A preview removes nothing, so as far as the exit status goes the group is
        # still standing: it must not report success for work it did not do.
        if $DRY_RUN; then
            audit_left=$((audit_left + 1))
        fi
        for (( j = 0; j < n; j++ )); do
            [[ "${dig[$j]:-}" == "$key" ]] || continue
            if [[ "$j" == "$keep" ]]; then
                continue
            fi
            if $DRY_RUN; then
                # run() is what echoes a command under -v, and a preview never reaches
                # it, so -v used to show every mv of a run and not one rm. The command
                # stands in for the prose here rather than sitting beside it, and in
                # that order: a line saying "would remove" after a command line that
                # looks like it ran reads as though the removal came second. Same rule
                # the rename path uses, where -v shows the mv and not "old -> new".
                if $VERBOSE; then
                    print_cmd rm -- "${a_names[j]}"
                else
                    printf '        would remove %s\n' "${a_names[j]}"
                fi
                COLLAPSED["${a_names[j]}"]=1
                deduped=$((deduped + 1))
                continue
            fi
            if run rm -- "${a_names[j]}"; then
                printf '        removed %s\n' "${a_names[j]}"
                COLLAPSED["${a_names[j]}"]=1
                log_action deduped "${a_names[j]}" "${a_names[keep]}" "same bytes as the one kept, $key"
                deduped=$((deduped + 1))
            else
                printf '        could not be removed, left in place: %s\n' "${a_names[j]}" >&2
                audit_left=$((audit_left + 1))
            fi
        done
    done

    audit_groups=$((audit_groups + groups))
    audit_extra=$((audit_extra + extra))
    audit_bytes=$((audit_bytes + bytes))
}

# Audit one folder, or the tree under it with -r, for identical bytes under
# different names. It renames nothing. Without -c it removes nothing and writes no
# log either: the log means things that happened, and an audit happens to nothing.
# With -c the removals are real, so they are logged as deduped and undoable.
audit_path() {
    local root="$1" rec rest dev ino size path dir i idx=0
    local -A dir_members=()
    local -a dir_order=() all_names=() all_sizes=() all_devino=()
    a_dir=""
    a_names=()
    a_sizes=()
    a_devino=()

    if [[ ! -e "$root" && ! -L "$root" ]]; then
        printf 'conform_naming: not found: %s\n' "$root" >&2
        skipped=$((skipped + 1))
        return 0
    fi
    if [[ -f "$root" ]]; then
        printf 'conform_naming: %s is one file, there is nothing to compare it with here\n' "$root" >&2
        return 0
    fi

    local find_args=("$root" -mindepth 1)
    if ! $RECURSIVE; then
        find_args+=(-maxdepth 1)
    fi
    # One find for the whole walk, carrying device, inode and size along with the
    # path, so a folder of unique sizes costs no hashing at all.
    #
    # Nothing hidden is compared, counted or collapsed, for the reason the rename walk
    # has plus one: a repository holds genuine byte-for-byte duplicates -- template
    # hooks, loose objects matching their packed copy -- that are not reclaimable, and
    # -c would be deleting from a working repository. Pruning keeps find from
    # descending at all, and -mindepth 1 keeps the starting point itself from matching
    # -name '.*' and pruning the whole run away.
    # The -o that separates the prune group from the printing branch goes after the
    # closing parenthesis; an -o left inside the group is a syntax error, and find then
    # walks nothing at all.
    find_args+=(\( -name .git -type d -prune -o -name '.*' -prune \) -o
                -type f -printf '%D|%i|%s|%p\0')

    if $VERBOSE; then
        print_cmd find "${find_args[@]}"
    fi

    # Records are bucketed by folder and only judged afterwards. A folder's own
    # files are NOT contiguous in path order whenever the folder also holds
    # subfolders -- ./.git/config, then ./.git/hooks/x.sample, then ./.git/index
    # puts three runs of ./.git on screen -- and no sort key can make them so. So
    # nothing here depends on the order records arrive in; the sort below only makes
    # the report come out in path order, which is all it is for.
    while IFS= read -r -d '' rec; do
        dev="${rec%%|*}"; rest="${rec#*|}"
        ino="${rest%%|*}"; rest="${rest#*|}"
        size="${rest%%|*}"
        path="${rest#*|}"                    # the path is last: it may hold a |

        dir="${path%/*}"
        [[ "$dir" == "$path" ]] && dir="."
        if [[ -n "${dir_members[$dir]+x}" ]]; then
            dir_members["$dir"]+=" $idx"
        else
            dir_members["$dir"]="$idx"
            dir_order+=("$dir")
        fi
        all_names+=("$path")
        all_sizes+=("$size")
        all_devino+=("$dev:$ino")
        idx=$((idx + 1))
    done < <(find "${find_args[@]}" | LC_ALL=C sort -z -t'|' -k4)

    # One folder at a time, all of its files in hand. The index lists hold nothing
    # but integers, so they are meant to be split into words here.
    for dir in "${dir_order[@]}"; do
        a_dir="$dir"
        a_names=()
        a_sizes=()
        a_devino=()
        for i in ${dir_members[$dir]}; do
            a_names+=("${all_names[i]}")
            a_sizes+=("${all_sizes[i]}")
            a_devino+=("${all_devino[i]}")
        done
        flush_dir
    done
}

# Replay a log backwards, newest action first. That is the order that works: a
# folder renamed after its contents has to be put back before they are moved into
# it. Refuses instead of overwriting at every step, so running it twice does
# nothing the second time beyond reporting what is already back in place.
undo_log() {
    local lines=() line i stamp action from to detail

    # tr drops carriage returns, so a log opened in a Windows editor still parses.
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "$line" && "$line" != '#'* ]]; then
            lines+=("$line")
        fi
    done < <(tr -d '\r' < "$UNDO_FILE")

    if [[ "${#lines[@]}" -eq 0 ]]; then
        printf 'conform_naming: nothing to undo in %s\n' "$UNDO_FILE" >&2
        return 0
    fi

    for (( i = ${#lines[@]} - 1; i >= 0; i-- )); do
        IFS=$'\t' read -r stamp action from to detail <<< "${lines[i]}"
        case "$action" in
            renamed)
                if [[ ! -e "$to" && ! -L "$to" ]]; then
                    printf 'undo: already gone, left alone: %s\n' "$to" >&2
                    log_skipped "$to" "$from" "undo: that name is gone already"
                    skipped=$((skipped + 1))
                elif name_taken "$from"; then
                    printf 'undo: name already in use, left alone: %s\n' "$from" >&2
                    log_skipped "$to" "$from" "undo: the original name is in use"
                    skipped=$((skipped + 1))
                elif ! run mv -- "$to" "$from"; then
                    printf 'undo: failed: %s -> %s\n' "$to" "$from" >&2
                    log_skipped "$to" "$from" "undo: mv was refused"
                    skipped=$((skipped + 1))
                else
                    PLANNED["$from"]=1
                    log_action undone "$to" "$from" "reversed one rename"
                    undone=$((undone + 1))
                fi
                ;;
            deduped)
                # The bytes are still at $to, so the dropped name can come back as
                # a second link to them rather than as a copy of them. cp is the
                # fallback for a filesystem without hardlinks.
                if [[ -e "$from" || -L "$from" ]]; then
                    printf 'undo: already present, left alone: %s\n' "$from" >&2
                    log_skipped "$to" "$from" "undo: the duplicate name is back already"
                    skipped=$((skipped + 1))
                elif [[ ! -e "$to" ]]; then
                    printf 'undo: cannot restore %s, the kept file %s is gone\n' "$from" "$to" >&2
                    log_skipped "$to" "$from" "undo: the kept file is gone, nothing to link to"
                    skipped=$((skipped + 1))
                elif run ln -- "$to" "$from" || run cp -p -- "$to" "$from"; then
                    PLANNED["$from"]=1
                    log_action unrestored "$to" "$from" "duplicate name recreated"
                    restored=$((restored + 1))
                else
                    printf 'undo: failed to restore: %s\n' "$from" >&2
                    log_skipped "$to" "$from" "undo: could not recreate the name"
                    skipped=$((skipped + 1))
                fi
                ;;
            duplicate|skipped|note)
                # Reporting, not work: there is nothing to reverse, and the run that
                # wrote them said why at the time. Silent on purpose.
                continue
                ;;
            undone|unrestored)
                printf 'undo: line %d came from an undo run, it is not replayed: %s\n' \
                    "$((i + 1))" "$action" >&2
                skipped=$((skipped + 1))
                ;;
            *)
                printf 'undo: unknown action %s on line %d\n' "$action" "$((i + 1))" >&2
                skipped=$((skipped + 1))
                ;;
        esac
    done
}

case "${1:-}" in
    ''|-h|--help) usage; exit 0 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true ;;
        -r|--recursive) RECURSIVE=true ;;
        -v|--verbose) VERBOSE=true ;;
        -a|--ascii) FOLD_ACCENTS=true ;;
        -k|--keep-both) KEEP_BOTH=true ;;
        -d|--duplicate) AUDIT=true ;;
        -c|--collapse) COLLAPSE=true ;;
        --log)
            if [[ $# -lt 2 ]]; then
                printf 'conform_naming: --log needs a file name\n' >&2
                exit 2
            fi
            LOG_FILE="$2"
            shift
            ;;
        --log=*) LOG_FILE="${1#--log=}" ;;
        --undo)
            if [[ $# -lt 2 ]]; then
                printf 'conform_naming: --undo needs a log file name\n' >&2
                exit 2
            fi
            UNDO_FILE="$2"
            shift
            ;;
        --undo=*) UNDO_FILE="${1#--undo=}" ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) printf 'conform_naming: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done

# Options that contradict an action are refused before anything inspects the files
# they name. `--undo run.log` combined with -c or -d is a contradiction whatever the
# log holds, and testing readability first made `-c --undo run.log` report "cannot
# read the log" -- a missing file standing in for a usage error, which sends the user
# looking in the wrong place entirely.
if [[ -n "$UNDO_FILE" ]]; then
    if $AUDIT; then
        printf 'conform_naming: -d and --undo are two different actions\n' >&2
        exit 2
    fi
    if $COLLAPSE; then
        printf 'conform_naming: -c and --undo are two different actions\n' >&2
        exit 2
    fi
fi

# --undo takes the log instead of paths, and only ever a log this script wrote.
if [[ -n "$UNDO_FILE" ]]; then
    if [[ $# -gt 0 ]]; then
        printf 'conform_naming: --undo replays a log, it takes no PATH\n' >&2
        exit 2
    fi
    if [[ ! -r "$UNDO_FILE" ]]; then
        printf 'conform_naming: cannot read the log: %s\n' "$UNDO_FILE" >&2
        exit 2
    fi
elif [[ $# -eq 0 ]]; then
    printf 'conform_naming: no PATH given\n' >&2
    usage >&2
    exit 2
fi

# -d is a report, so it must not be mistaken for the mode that changes things.
if $AUDIT; then
    if $KEEP_BOTH; then
        printf 'conform_naming: -d replaces the renaming, so it cannot be combined with -k\n' >&2
        exit 2
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v cksum >/dev/null 2>&1; then
        printf 'conform_naming: -d needs sha256sum or cksum and neither is installed\n' >&2
        exit 2
    fi
    if ! $COLLAPSE && $DRY_RUN; then
        printf 'conform_naming: -n has nothing to preview with -d, which changes nothing\n' >&2
    fi
fi

# -c is the one option allowed to remove files that -d found, so it has to be
# pointed at something: an audit to collapse, or a rename to clear the way for.
if $COLLAPSE; then
    if ! $AUDIT && ! $KEEP_BOTH; then
        printf 'conform_naming: -c collapses duplicates; give it -d to audit them or -k to rename after\n' >&2
        exit 2
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v cksum >/dev/null 2>&1; then
        printf 'conform_naming: -c needs sha256sum or cksum and neither is installed\n' >&2
        exit 2
    fi
fi

# -k and -c can drop a duplicate, so neither runs unrecorded. The log is opened before
# anything is renamed: an unwritable log must not turn up halfway through a run.
# A dry run is a preview rather than a record, so it neither writes nor leaves a
# file behind in the folder being tidied -- redirect its output to keep one.
if $DRY_RUN || { $AUDIT && ! $COLLAPSE; }; then
    LOG_FILE=""
else
    if [[ -z "$LOG_FILE" ]] && { $KEEP_BOTH || $COLLAPSE || [[ -n "$UNDO_FILE" ]]; }; then
        LOG_FILE="conform_naming-$(date +%Y%m%dT%H%M%S).log"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        RUN_STAMP="$(date +%Y-%m-%dT%H:%M:%S%z)"
        if ! : >> "$LOG_FILE"; then
            printf 'conform_naming: cannot write the log, nothing renamed: %s\n' "$LOG_FILE" >&2
            exit 2
        fi
        printf '# %s\t%s\n# stamp\taction\tfrom\tto\tdetail\n' \
            "$RUN_STAMP" "$0 $INVOCATION" >> "$LOG_FILE"
    fi
fi

# In undo mode there are no PATH arguments left, so the loop below is skipped.
if [[ -n "$UNDO_FILE" ]]; then
    undo_log
fi

for target_path in "$@"; do
    # Only the filesystem root is refused: a recursive walk from there would try
    # to rename system directories. "." is fine -- find never matches "." or
    # "./" itself, so only their contents are renamed.
    if [[ "$target_path" =~ ^/+$ ]]; then
        printf 'conform_naming: refusing to rename the filesystem root\n' >&2
        skipped=$((skipped + 1))
        continue
    fi
    # With -c and -k the duplicates are collapsed first, so the names chosen
    # afterwards have fewer clashes to work around, and the ones left are between
    # files that genuinely differ. The log therefore holds the removals below the
    # renames, which is the order --undo replays in reverse: names back first, then
    # the renames.
    if $AUDIT || $COLLAPSE; then
        audit_path "$target_path"
    fi
    if $AUDIT; then
        continue
    fi
    if $RECURSIVE; then
        rename_recursive "$target_path"
    else
        rename_path "$target_path"
    fi
done

if [[ -n "$UNDO_FILE" ]]; then
    if $DRY_RUN; then
        printf 'dry run: %d to move back, %d duplicate names to recreate\n' \
            "$undone" "$restored"
    else
        printf 'moved back %d, recreated %d duplicate names\n' "$undone" "$restored"
    fi
fi

if $DRY_RUN; then
    [[ $renamed -gt 0 ]] && printf '\n%d entr%s to rename (dry run, nothing changed)\n' \
        "$renamed" "$([[ $renamed -eq 1 ]] && echo y || echo ies)"
else
    [[ $renamed -gt 0 ]] && printf 'renamed %d entr%s\n' \
        "$renamed" "$([[ $renamed -eq 1 ]] && echo y || echo ies)"
fi
if [[ $deduped -gt 0 ]]; then
    if $DRY_RUN; then
        printf 'would remove %d duplicate%s, one copy of each kept\n' \
            "$deduped" "$([[ $deduped -eq 1 ]] && echo "" || echo s)"
    else
        printf 'removed %d duplicate%s, one copy kept of each%s\n' "$deduped" \
            "$([[ $deduped -eq 1 ]] && echo "" || echo s)" \
            "$([[ -n "$LOG_FILE" ]] && echo ", see $LOG_FILE")"
    fi
fi
if [[ $duplicates -gt 0 ]]; then
    printf 'kept %d file%s whose bytes another file wanting the same name already holds -- all still there, listed as duplicate in the log\n' \
        "$duplicates" "$([[ $duplicates -eq 1 ]] && echo "" || echo s)"
fi
if $DRY_RUN && { $KEEP_BOTH || $COLLAPSE; }; then
    printf 'dry run: nothing removed and nothing logged; pipe this output to a file to keep the plan\n'
fi
[[ -n "$LOG_FILE" ]] && printf 'log: %s\n' "$LOG_FILE" || true
[[ $skipped -gt 0 ]] && printf 'skipped %d\n' "$skipped" >&2 || true
[[ $notes -gt 0 ]] && printf 'check %d name%s still outside A-Za-z0-9._+-\n' \
    "$notes" "$([[ $notes -eq 1 ]] && echo "" || echo s)" >&2 || true

if $AUDIT; then
    if (( audit_groups == 0 )); then
        printf 'no duplicates: no two files in one folder hold the same bytes\n'
    else
        printf '\n%d duplicate group%s, %d extra cop%s, %s reclaimable\n' "$audit_groups" \
            "$([[ $audit_groups -eq 1 ]] && echo '' || echo s)" \
            "$audit_extra" "$([[ $audit_extra -eq 1 ]] && echo 'y' || echo 'ies')" \
            "$(human_bytes "$audit_bytes")"
    fi
    if (( hardlinked > 0 )); then
        printf '%d name%s were another link to a file already counted, not duplicates\n' \
            "$hardlinked" "$([[ $hardlinked -eq 1 ]] && echo '' || echo s)"
    fi
    if $COLLAPSE; then
        if (( audit_left == 0 )); then
            printf 'every group is down to one copy%s\n' \
                "$([[ -n "$LOG_FILE" ]] && echo ", see $LOG_FILE")"
        elif $DRY_RUN; then
            printf 'dry run: %d group%s untouched, %d cop%s would go\n' "$audit_left" \
                "$([[ $audit_left -eq 1 ]] && echo '' || echo s)" "$deduped" \
                "$([[ $deduped -eq 1 ]] && echo 'y' || echo 'ies')"
        else
            printf '%d group%s still there, see the lines above\n' "$audit_left" \
                "$([[ $audit_left -eq 1 ]] && echo '' || echo s)" >&2
        fi
    fi
    # A report you have to read is a report nobody scripts. Duplicates in place: 1.
    # With -c that means groups left standing -- empty ones, or a file that would
    # not unlink -- not the ones that were collapsed away.
    (( audit_left == 0 )) || exit 1
fi
