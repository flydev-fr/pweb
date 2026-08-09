#!/usr/bin/env python3
"""Archive les entrees des epics clos hors de sprint-status.yaml.

Pourquoi : sprint-status.yaml est append-only. Il grossit a chaque story et ne
retrecit jamais, donc la session de l'epic 12 paie encore l'epic 1. Ce script
deplace les blocs des epics termines vers un fichier d'archive et laisse une
ligne-repere a leur place.

Volontairement TEXTUEL, pas base sur yaml.safe_load : ces fichiers contiennent
des annotations en texte libre qui cassent les parseurs YAML stricts (un ':'
dans un commentaire suffit). On ne reformate rien, on deplace des lignes.

Sans --apply, le script n'ecrit rien (dry-run par defaut).

    python archive-epic.py --file _bmad-output/implementation-artifacts/sprint-status.yaml
    python archive-epic.py --file ... --epic 1 --epic 2 --apply
    python archive-epic.py --file ... --all-done --apply
"""

import argparse
import io
import os
import re
import shutil
import sys

BLOCK_KEY = "development_status:"

# Marque les lignes d'en-tete que ce script (re)genere, pour pouvoir les
# reconstruire au lieu de les empiler a chaque passe.
ARCHIVE_TAG = "# [archive]"
# Marque une ligne 'epic-N:' deja archivee, pour ne pas la re-archiver.
ARCHIVED_MARK = "# archive ->"

EPIC_RE = re.compile(r"^(\s+)epic-(\d+)\s*:\s*([^\s#]+)")
STORY_RE = re.compile(r"^(\s+)(\d+)-(\d+)[a-zA-Z0-9_-]*\s*:\s*([^\s#]+)")
EPIC_SUB_RE = re.compile(r"^(\s+)epic-(\d+)-[a-zA-Z0-9_-]+\s*:\s*([^\s#]+)")


def read_lines(path):
    with io.open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read().splitlines(keepends=True)


def find_block(lines):
    """Retourne (start, end) des lignes du bloc development_status, fin exclue."""
    start = None
    for i, line in enumerate(lines):
        if line.strip().startswith(BLOCK_KEY):
            start = i + 1
            break
    if start is None:
        return None, None
    end = len(lines)
    for j in range(start, len(lines)):
        stripped = lines[j]
        # Une cle non indentee termine le bloc.
        if stripped.strip() and not stripped[0].isspace() and not stripped.lstrip().startswith("#"):
            end = j
            break
    return start, end


def epic_of(line):
    """Numero d'epic auquel appartient une ligne, ou None."""
    m = EPIC_SUB_RE.match(line)
    if m:
        return int(m.group(2))
    m = EPIC_RE.match(line)
    if m:
        return int(m.group(2))
    m = STORY_RE.match(line)
    if m:
        return int(m.group(2))
    return None


def epic_status(lines, start, end):
    """Statut declare de chaque epic, depuis sa ligne 'epic-N:'."""
    status = {}
    for i in range(start, end):
        m = EPIC_RE.match(lines[i])
        if m:
            status[int(m.group(2))] = m.group(3).strip().lower()
    return status


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", required=True, help="chemin de sprint-status.yaml")
    ap.add_argument("--archive-dir", default=None,
                    help="dossier d'archive (defaut: <dossier du fichier>/archive)")
    ap.add_argument("--epic", type=int, action="append", default=[],
                    help="numero d'epic a archiver (repetable)")
    ap.add_argument("--all-done", action="store_true",
                    help="archiver tous les epics dont le statut est 'done'")
    ap.add_argument("--apply", action="store_true",
                    help="ecrire les modifications (sinon dry-run)")
    args = ap.parse_args()

    path = os.path.abspath(args.file)
    if not os.path.isfile(path):
        print("ERREUR: fichier introuvable: %s" % path, file=sys.stderr)
        return 2

    archive_dir = args.archive_dir or os.path.join(os.path.dirname(path), "archive")
    lines = read_lines(path)
    start, end = find_block(lines)
    if start is None:
        print("ERREUR: bloc '%s' introuvable dans %s" % (BLOCK_KEY, path), file=sys.stderr)
        return 2

    statuses = epic_status(lines, start, end)
    if not statuses:
        print("ERREUR: aucune ligne 'epic-N:' trouvee dans le bloc.", file=sys.stderr)
        return 2

    if args.all_done:
        targets = sorted(n for n, s in statuses.items() if s == "done")
    else:
        targets = sorted(set(args.epic))

    if not targets:
        print("Rien a archiver. Epics connus: %s" % ", ".join(
            "%d=%s" % (n, statuses[n]) for n in sorted(statuses)))
        return 0

    # Epics deja archives par une passe precedente : ne pas les retraiter,
    # sinon leur ligne-repere partirait a son tour dans l'archive.
    already = set()
    for i in range(start, end):
        m = EPIC_RE.match(lines[i])
        if m and ARCHIVED_MARK in lines[i]:
            already.add(int(m.group(2)))
    skipped = sorted(n for n in targets if n in already)
    if skipped:
        print("Deja archives, ignores: %s\n"
              % ", ".join("epic-%d" % n for n in skipped))
        targets = [n for n in targets if n not in already]
        if not targets:
            print("Rien de nouveau a archiver.")
            return 0

    refused = [n for n in targets if statuses.get(n) != "done"]
    if refused:
        print("REFUS: ces epics ne sont pas 'done', ils ne seront pas archives: %s"
              % ", ".join("epic-%d (%s)" % (n, statuses.get(n, "absent")) for n in refused),
              file=sys.stderr)
        targets = [n for n in targets if n not in refused]
        if not targets:
            return 1

    # Partition des lignes du bloc. L'en-tete d'une passe precedente est
    # ecarte ici puis reconstruit plus bas, pour rester a jour et unique.
    keep, moved = [], {n: [] for n in targets}
    for i in range(start, end):
        line = lines[i]
        if ARCHIVE_TAG in line:
            continue
        n = epic_of(line)
        if n in moved:
            moved[n].append(line)
        else:
            keep.append(line)

    total_moved = sum(len(v) for v in moved.values())
    saved = sum(len(l.encode("utf-8")) for v in moved.values() for l in v)

    print("Fichier      : %s" % path)
    print("Bloc         : lignes %d-%d" % (start + 1, end))
    print("Archive vers : %s" % archive_dir)
    print("")
    for n in targets:
        print("  epic-%-3d %3d lignes -> epic-%d.yaml" % (n, len(moved[n]), n))
    print("")
    print("Total: %d lignes deplacees, ~%.1f Ko retires de sprint-status.yaml"
          % (total_moved, saved / 1024.0))

    if not args.apply:
        print("\n[DRY-RUN] Rien n'a ete ecrit. Relancez avec --apply pour appliquer.")
        return 0

    os.makedirs(archive_dir, exist_ok=True)
    backup = path + ".bak"
    shutil.copy2(path, backup)

    for n in targets:
        dest = os.path.join(archive_dir, "epic-%d.yaml" % n)
        with io.open(dest, "w", encoding="utf-8", newline="") as fh:
            fh.write("# Archive de l'epic %d, extrait de %s\n" % (n, os.path.basename(path)))
            fh.write("# Epic clos : ces entrees ne sont plus chargees par les sessions courantes.\n")
            fh.write("development_status:\n")
            for line in moved[n]:
                fh.write(line)

    marker = []
    total_stories = 0
    for n in targets:
        stories = sum(1 for l in moved[n] if STORY_RE.match(l))
        total_stories += stories
        marker.append("  epic-%d: done   # archive -> archive/epic-%d.yaml (%d stories)\n"
                      % (n, n, stories))

    # En-tete explicite. Plusieurs skills portent l'instruction "MUST read
    # COMPLETE sprint-status file" et resolvent les stories par correspondance
    # exacte de cle : sans ce bloc, l'archivage ressemble a une amputation
    # silencieuse. Il dit ou est passe le reste et comment le retrouver.
    archived_all = sorted(set(targets) | already)
    span = ", ".join("epic-%d" % n for n in archived_all)
    archive_name = os.path.basename(archive_dir.rstrip("/\\")) or "archive"
    header = [
        "  %s -----------------------------------------------------------\n" % ARCHIVE_TAG,
        "  %s %s archives (statut done) -> ./%s/epic-<N>.yaml\n"
        % (ARCHIVE_TAG, span, archive_name),
        "  %s %d stories closes y resident. AUCUNE donnee supprimee.\n"
        % (ARCHIVE_TAG, total_stories),
        "  %s Une cle de story absente de ce bloc n'est pas manquante :\n" % ARCHIVE_TAG,
        "  %s lire ./%s/epic-<N>.yaml pour l'epic correspondant.\n"
        % (ARCHIVE_TAG, archive_name),
        "  %s -----------------------------------------------------------\n" % ARCHIVE_TAG,
    ]

    new_lines = lines[:start] + header + keep + marker + lines[end:]
    with io.open(path, "w", encoding="utf-8", newline="") as fh:
        fh.writelines(new_lines)

    print("\nApplique. Sauvegarde: %s" % backup)
    print("Verifiez le resultat, puis supprimez le .bak quand vous etes satisfait.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
