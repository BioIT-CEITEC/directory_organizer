# directory_organizer
set of scripts to help reorganizing a directory according to the CEITEC BioIT guideline

## conform_naming.sh

Renames files and folders to the naming rules: spaces become underscores, and with `-a`
accented Latin letters fold to plain ASCII. It also settles what happens when two names
collapse onto one (`-k`), reports files stored twice under different names (`-d`), can
collapse those to one copy (`-c`), and can put any logged run back afterwards (`--undo`).

Only the name itself is rewritten — the folder a file sits in is never changed, so
`/data/raw data/a file.txt` becomes `/data/raw data/a_file.txt`, not `/data/raw_data/...`.
Nothing is ever overwritten, every option that changes something previews with `-n`, and
nothing whose name starts with a dot is touched at all.

Needs bash 4 or newer and GNU `find`/`sort`, so any current Linux is fine.

### Quick start

```bash
chmod +x conform_naming.sh

./conform_naming.sh -n -r .        # 1. preview every spaced name below the current folder
./conform_naming.sh -r .           # 2. apply it
./conform_naming.sh -n -r -a .     # the same, also folding accents: é -> e, ř -> r
./conform_naming.sh -n -r -a -k .  # the same, also resolving clashes: read the note on -k
./conform_naming.sh -d -r .        # what is stored twice, and what it costs
./conform_naming.sh -n -d -r -c .  # preview collapsing those into one copy each

./test_conform_naming.sh           # 41 cases, 147 checks, all inside temp folders
```

Every option that changes something accepts `-n`, and `-n` is never a bad idea: it
prints the plan, touches nothing and writes no log.

### Usage

```
./conform_naming.sh [options] PATH [PATH ...]
```

| Option | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print what would change, rename nothing. |
| `-r`, `--recursive` | Rename everything inside each PATH as well, deepest entries first. |
| `-a`, `--ascii` | Also fold accented Latin letters to plain ASCII: `é → e`, `ř → r`, `ß → ss`, `æ → ae`. Case is preserved. |
| `-k`, `--keep-both` | Resolve a name clash instead of skipping it, keeping both files. A file that turns out to hold bytes an already-numbered sibling holds is kept as well, and reported. Always writes a log. See below. |
| `--log FILE` | Where to append that log. Defaults to `conform_naming-<timestamp>.log` in the current directory. |
| `--undo FILE` | Reverse a logged run instead of renaming: renames move back, and a name dropped as a duplicate is recreated. Takes the log in place of paths. |
| `-d`, `--duplicate` | Audit instead of renaming: report files in the same folder holding identical bytes, whatever they are called. On its own it changes nothing and writes no log, and exits 1 when it finds any. |
| `-c`, `--collapse` | Remove those duplicates, keeping one copy of each. With `-d`, collapse what the audit finds; with `-k`, collapse first and rename afterwards. Writes a log, so `--undo` puts the names back. |
| `-v`, `--verbose` | Echo the `find`, `mv` and `rm` commands as they run, shell-quoted. With `-n` they are shown and not executed — and they stand in for the `old -> new` lines, so a verbose preview is a list of the exact commands a real run would use. |
| `-h`, `--help` | Show the help. |

Exit status: **0** the run did what was asked and nothing is outstanding, **1** duplicates
are still standing (found by `-d`, or left in place by `-c`), **2** a usage error, before
anything is touched.

```bash
./conform_naming.sh "raw data"                # raw data -> raw_data
./conform_naming.sh "a file.txt" "b dir"      # several paths at once
./conform_naming.sh -r "project one"          # the contents, then the folder itself
./conform_naming.sh -a "Café 2024"            # Cafe_2024
./conform_naming.sh -n -r -a -k .             # a full tidy-up, previewed
./conform_naming.sh --undo conform_naming-20261127T091402.log   # put that run back
./conform_naming.sh -d -r .                   # what is duplicated, and what it costs
./conform_naming.sh -n -d -r -c .             # preview collapsing them into one copy each
./conform_naming.sh -n -r -a -k -v .          # the exact commands, nothing executed
./conform_naming.sh --log tidy.log -r -a -k . # one named log for a run worth keeping
./conform_naming.sh -- "-odd name.txt"        # names starting with a dash need --
```

### Behaviour to know about

- **Nothing is ever overwritten.** If `a_file.txt` already exists, `a file.txt` is
  left alone and reported. That default is on purpose: a clash usually means two
  different files want one name, and only you know which is which.
- **`-k` settles a clash and keeps both files.** If the bytes are the same, the
  content is kept once — the redundant copy is removed after a size and checksum
  comparison. If they differ, the newcomer is numbered: `report_1.txt`, `report_2.txt`,
  extension kept.
- **Identical files that wanted the same name are kept, and reported.** When the bytes
  being placed are already held by one of the numbered siblings, the script prints
  `duplicate kept: …`, counts it in the summary and writes a `duplicate` record with the
  digest — and keeps both files. A collision onto one name does not prove the two
  meant the same thing. `grep -P '\tduplicate\t' conform.log` is the list to work
  through; `sha256sum * | sort | uniq -w64 -D` finds any others in a folder.
- **`-k` and `-c` can remove a file, so neither runs unrecorded**: every action goes to a
  log, opened before anything is renamed and named `conform_naming-<timestamp>.log` unless
  `--log` says otherwise. If the log cannot be written, the run refuses to start. Preview
  with `-n` first; a preview writes nothing, to the folder or to the log.
- **Any logged run can be put back with `--undo LOG`.** It replays newest action first,
  which is the order that works when folders moved too, and it refuses to displace a
  name something else has taken — so running it twice does nothing the second time
  beyond reporting what is already back in place. A name dropped as a duplicate comes
  back as a link to the copy that was kept, since those bytes were never lost. The undo
  is logged in its own new log. Preview with `-n`; only undo logs this script wrote.
  Run it from the directory the original run was started in — the log holds the paths
  as they were given, not absolute ones, and an undo from elsewhere simply will not
  find them.
- **Entries are handled in sorted order**, so the same folder renamed twice gives the
  same names twice. Otherwise which of `cafe.txt` and `café.txt` keeps the clean name
  depends on the order the filesystem happens to report them in.
- **One preview cannot match reality exactly.** During `-n` nothing is renamed yet, so
  a file that would be a duplicate of something not yet moved reads as a numbered clash
  rather than a duplicate. Everything else is shown as it will happen.
- **Recursive runs work from the bottom up**, so paths stay valid while it works
  upwards. The PATH you give is renamed too, after its contents.
- **`.` and `./` are accepted with `-r`** and mean the current folder's contents;
  the folder you are standing in is never renamed. The filesystem root is refused.
- **Spaces, and with `-a` accented letters, are all it touches.** Tabs, newlines,
  parentheses and other characters are left alone — deciding those needs a human,
  not a wildcard.
- **`-a` folds Latin letters from a table**, not through `iconv`, so the same name
  gives the same result on any machine. Case is kept, `ß` becomes `ss`, `æ` becomes
  `ae`. Non-Latin names (Greek, Cyrillic, CJK) pass through unchanged.
- **`-a` reports what it could not settle.** A name still outside `A-Za-z0-9._+-`
  after folding prints `still not naming-safe: <name>`, is counted at the end, and
  goes in the log as a `note` line, ready to work through later. The fold table sits in one block near the top of the script,
  if a letter needs a different reading (`ø → oe` rather than `o`, say).
- **Folding can create a clash**: `café` and `cafe` want the same name. Whichever is
  reached second is skipped and reported, never overwritten.
- **A problem does not stop the run.** A missing path, a clash or a refused `mv`
  prints a warning on stderr, adds to the `skipped N` total, leaves a `skipped` line
  in the log with the reason, and continues with the next entry. Renaming therefore
  exits 0 even when entries were skipped — `skipped N` on stderr is the signal, and a
  usage error is the only thing that stops a run before it starts (exit 2). The audit
  keeps exit 1 for itself, since that is the one thing worth scripting on.
- **`-v` is the way to see what it will really do.** It echoes `find`, `mv` and `rm`
  shell-quoted, which is also the fastest way to catch a mistake: a wrong filter or a
  wrong target is visible in the command line before anything has moved.
- **No hidden entry is ever touched** — nothing whose name starts with a dot is entered,
  renamed, compared or collapsed. `.git` is the reason that became a rule rather than a
  hint: renaming a loose object or a ref breaks a repository in silence, and `-c` would
  unlink git's own files. The same protection covers `.cache`, `.config`, `.bashrc` and
  a `".hidden data.txt"` you never meant to tidy. Point the script at a data folder, not
  at a home directory, and if you do mean a hidden name, **type it yourself** — a walk
  falling on `.secrets` and you asking for `.secrets` are two different things, and only
  the second one renames anything.

### Auditing for duplicates

`-d` answers a different question from every other option: not *what should this be
called* but *is this the same thing twice*. On its own it renames nothing, so it is safe
to run as often as you like.

```
$ ./conform_naming.sh -d -r .
./raw: 2 duplicate groups, 3 extra copies, 204.0 MB reclaimable
    sha256:9f2a1c3b4d5e6f708  4.1 MB  x2
        ./raw/run_01.fastq
        ./raw/copy of run_01.fastq
    sha256:41bc02de15f309915  200.0 MB  x3
        ./raw/lane1.fq.gz
        ./raw/lane1 copy.fq.gz
        ./raw/lane1_copy.fq.gz

2 duplicate groups, 3 extra copies, 204.0 MB reclaimable
$ echo $?
1
```

Only files in the **same folder** are compared. Identical bytes in two folders are
usually deliberate — a reference file, a template copied per experiment — and sweeping
those into the same report buries the real accidents under things that were meant to be
there.

Three choices keep it cheap enough to run on a data folder:

- **Size first.** A file whose size is unique in the folder cannot have a twin, so it is
  never opened. A folder of unique sizes costs one directory walk and no hashing.
- **Links are not duplicates.** Two names on one inode are one file, counted aside and
  never reported. That matters for a specific reason here: `--undo` recreates a removed
  duplicate as a link, so a naive audit would report its own work back at you.
- **An unreadable file is skipped and named**, not treated as a twin of the other
  unreadable one: a failed checksum leaves an empty digest, and empty digests match
  each other.

Hidden entries are not compared either, so a folder of dot-files is quietly out of scope
— see the rule above.

It writes no log on its own, because the log records what happened and an audit happens
to nothing — redirect the report if you want it kept. It exits **1** when it finds
duplicates and **0** when the folders are clean, so `./conform_naming.sh -d -r . || echo
tidy first` works as a gate. Combining `-d` with `-k` is refused outright: `-d` replaces
the renaming, and `-k` is a rule about renaming.

### Collapsing them with `-c`

`-d` tells you what is redundant; `-c` removes it. It is the only option that deletes a
file the user did not ask about by name, so the whole design leans on that:

```
$ ./conform_naming.sh -d -c --log conform.log .
./raw: 1 duplicate group, 2 extra copies, 410.0 MB reclaimable
    sha256:41bc02de15f309915  205.0 MB  x3  keeping ./raw/lane1.fq.gz
        removed ./raw/lane1 copy.fq.gz
        removed ./raw/lane1_copy.fq.gz

1 duplicate groups, 2 extra copies, 410.0 MB reclaimable
every group is down to one copy, see conform.log
```

- **Only files in the same folder, only files proven identical** — same size, then the
  same digest. Two names on one inode are one file and are never touched.
- **Which name survives is decided, not left to chance.** The copy *nearest the rules*
  keeps its name: count the characters that would have to change — a space, an accent —
  and fewer wins. So `report.txt` (nothing to fix) beats `report copy.txt` (one space).
  If two copies need the same number of fixes, the shorter name wins, and then the order
  the folder listed them in. `-c` before `-r -a -k` therefore clears the clash before a
  name has to be chosen at all.
- **The survivor can still be renamed afterwards.** Choosing the nearest-the-rules name
  is not the same as choosing the name that is free: if the copy that survives folds onto
  a name some *different* file already holds, `-k` numbers it as it always would. That is
  a naming question rather than a duplicate one, and the two decisions stay separate.
- **A preview plans exactly what the run will do.** Under `-n` nothing is really removed,
  so the collapse pass marks what it would have taken and the rename pass then leaves
  those files alone: no line renames a file that another line deletes. What a preview
  cannot show is what a removal would have prevented — a numbered name that will not be
  needed in the real run still shows as numbered in the preview.
- **The kept file is never rewritten.** Nothing is copied or truncated; its twins are
  unlinked, and each removal is logged as `deduped` with the survivor in the `to` column.
  `--undo` therefore puts every removed name back, as a hard link to the copy kept — the
  bytes were never lost, so restoring them costs no space.
- **Empty files are reported and left alone.** There is nothing to reclaim, and an empty
  file is often a deliberate placeholder. A folder whose only duplicates are empty keeps
  exiting 1 under `-c` for that reason.
- **`-c` with `-k` collapses first, then renames.** The clashes left afterwards are
  between files that genuinely differ, which is the case `-k` was built for.
- **It reads what it compares.** The size gate means a folder of unique sizes costs no
  hashing at all, but a folder of same-sized files is read in full, twice over with `-r`.
  On a sequencing folder that is the job; preview with `-n` and time it once before
  making it a habit.
- **A preview is not a run.** `-n` says `would remove` for each, counts the group as still
  standing, and exits 1 — it has not earned a 0.

### The log

One action per line, fields separated by a tab, `#` lines are headers.

| Column | Contents |
| --- | --- |
| `stamp` | When the run started, ISO 8601 |
| `action` | `renamed` or `deduped` for work done; `skipped`, `note` and `duplicate` for what did not move, what still needs a hand, and what looks redundant but was kept. An undo run also writes `undone` and `unrestored`. `deduped` covers both ways a redundant copy goes: `-k` finding the bytes already at the target name, and `-c` collapsing a folder. |
| `from` | The path as it was |
| `to` | The path it became, or for `deduped` the file that was kept |
| `detail` | Why: the checksum that proved two files identical, or `numbered instead of <name>` |

```
# 2026-11-27T09:14:02+0100	conform_naming.sh -r -a -k .
# stamp	action	from	to	detail
2026-11-27T09:14:02+0100	renamed	./Café 2024.txt	./Cafe_2024.txt	
2026-11-27T09:14:02+0100	renamed	./sub/report copy.txt	./sub/report_1.txt	numbered instead of ./sub/report.txt; sha256:9f2a… vs sha256:41bc…
2026-11-27T09:14:02+0100	deduped	./cafe.txt	./Cafe.txt	identical sha256:7d0f…
2026-11-27T09:14:02+0100	deduped	./raw/lane1 copy.fq.gz	./raw/lane1.fq.gz	same bytes as the one kept, sha256:41bc…
2026-11-27T09:14:02+0100	duplicate	./test file 1.txt	./test_file_1_4.txt	same bytes as ./test_file_1_3.txt, both kept sha256:961b6dd3…
2026-11-27T09:14:02+0100	skipped	./data (raw).txt	./data_(raw).txt	target already exists, rename it or use -k
2026-11-27T09:14:02+0100	note	./Cafe_(2024).txt		left as is, as far as the fold table could take it
```

`--undo` replays only the records of work it can reverse. It passes over `skipped` and
`note` without comment, and refuses `undone` / `unrestored` rather than applying an
undo of an undo, so the whole log of a run can be handed back to it as it stands.

Two deliberate gaps. A plain rename has an empty `detail`: the digests on a clash are
recorded because they are what decided it, but hashing a 200 GB file merely to annotate
its rename costs far more than the rename does. And a name holding a tab or a newline
cannot be written in this format at all, so it is reported and left out — which also
means `--undo` cannot reverse that entry; rename it by hand.

### Tests

```bash
./test_conform_naming.sh     # 41 cases, 147 checks, exits nonzero if any fails
```

No dependencies beyond bash and coreutils, and nothing outside a temp folder is touched:
each case builds its own tree with `printf` and `mkdir`, runs the script inside it, then
asserts on the folder, the log and the output. A full pass is one `ok` line per check,
each worded as a sentence about behaviour rather than about code.

The cases cover the rules that are easy to break silently — renaming and folding, clash
handling with and without `-k`, the log and what `--undo` can put back, the audit's
grouping (a folder's own files are not contiguous in path order once it holds subfolders),
collapsing and which copy survives, the hidden-entry rule, and that both `find`
expressions actually parse. Two habits in the case data are worth keeping if you add to
it, both learned the hard way:

- **A clash has to be built on purpose.** `"a b.txt"` wants `a_b.txt`, so an existing
  `a_b.txt` is a clash and an existing `report.txt` is not — a fixture built from names
  that never collide tests nothing and looks convincing. The same for folding: two names
  collide only if their accents sit where the table folds them onto the same word, so
  `càfe.txt` and `cáfe.txt` clash while `cafeé.txt` simply gains an `e`.
- **If a case expects something to be gone, prove it was the removal that happened.**
  "the duplicate was removed" and "the name came back" are also exactly what a plain
  rename and its undo look like, which is how one case passed green for months while
  never exercising a dedupe at all — it took a green suite to hide that one.

Linux only, as the intro says: the walks rely on GNU `find -printf`, which BSD and macOS
`find` do not have.
