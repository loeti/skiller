# skill-tool

Findet Agent-Skills in Registries, checkt sie lokal aus und macht sie über Symlinks
gruppierbar.

## Modell

```
agentic-workspace/
├── .skilltool/
│   ├── config.json              Quellen, Clone-Tiefe
│   ├── lock.json                welcher Skill aus welchem Repo/Commit
│   └── last-search.json         damit `add <nummer>` funktioniert
├── downloads/
│   └── github.com/<owner>/<repo>/      git clone (default --depth 1)
├── installs/
│   └── <name>  →  ../downloads/github.com/<owner>/<repo>/<skill-pfad>
└── skills/
    ├── swiftui/<name>  →  ../../installs/<name>
    └── ios/<name>      →  ../../installs/<name>      derselbe Skill, zweite Gruppe
```

Drei Ebenen, drei Aufgaben:

- **downloads/** ist ein Cache, den das Tool besitzt. Nicht von Hand editieren — `sync --update`
  macht ein `git reset --hard`.
- **installs/** ist die flache Liste aller verfügbaren Skills. Ein Eintrag ist entweder ein
  Symlink in einen Clone (Herkunft: `git`) oder ein echtes Verzeichnis (Herkunft: `local`,
  via `adopt`).
- **skills/** gehört dir. Beliebig tief verschachtelte Gruppen, jeder Eintrag ein Symlink nach
  `installs/`. Ein Skill kann in beliebig vielen Gruppen liegen, ohne kopiert zu werden.

Alle Symlinks sind relativ — der Workspace lässt sich verschieben oder auf eine andere
Maschine syncen, ohne dass etwas bricht.

## Installation

```sh
swift build -c release
cp .build/release/skill-tool /usr/local/bin/
```

## Workspace finden

In dieser Reihenfolge: `--workspace <pfad>` → `$AGENTIC_WORKSPACE` → nächstes
Elternverzeichnis mit `.skilltool/`.

```sh
export AGENTIC_WORKSPACE=/Volumes/Tools/agentic-workspace
skill-tool init "$AGENTIC_WORKSPACE"
```

## Kommandos

| Kommando | Wirkung |
|---|---|
| `search <query>` | Sucht in allen Quellen, dedupliziert, nummeriert |
| `index [--refresh]` | Lokalen Registry-Index anzeigen bzw. neu laden |
| `add <ref\|nummer>` | Clone → `installs/`-Link → optional Gruppen-Link → Lockfile |
| `link <gruppe> <name>…` | Skill in eine Gruppe legen (wird bei Bedarf angelegt) |
| `unlink <gruppe> <name>…` | Aus der Gruppe entfernen, Install bleibt |
| `list` / `list --groups` | Installierte Skills bzw. Gruppenbaum |
| `info <name\|ref>` | Details zu einem Skill — installiert oder noch nicht |
| `sync` / `sync --update` | Lockfile → Ist-Zustand, bzw. auf neuen Commit ziehen |
| `remove <name> [--prune]` | Install + alle Gruppen-Links weg; `--prune` löscht auch den Clone |
| `adopt [pfad…]` | Bestehende echte Verzeichnisse unter `skills/` übernehmen |
| `doctor` | Meldet Inkonsistenzen, ändert nie etwas |

Referenzformen für `add`: `owner/repo`, `owner/repo/skill-id`, `owner/repo/skill@ref`,
`https://github.com/owner/repo/tree/main/skills/x`, `git@github.com:owner/repo.git`, oder die
Nummer einer Zeile aus der letzten Suche.

`owner/repo` ohne Skill-ID installiert **alle** Skills des Repos.

## Typischer Ablauf

```sh
skill-tool search swiftui
skill-tool add 3 --group swiftui
skill-tool link ios swiftui-expert-skill    # derselbe Skill, zweite Gruppe
skill-tool list --groups
```

## Migration bestehender Verzeichnisse

`skills/` enthält oft schon von Hand hinkopierte Skills. `adopt` verschiebt sie nach
`installs/` und hinterlässt am alten Ort einen Symlink — die Gruppierung bleibt also erhalten:

```sh
skill-tool adopt --dry-run          # erst anschauen
skill-tool adopt                    # alle Kandidaten unter skills/
skill-tool adopt --suggest          # zusätzlich nach Upstream-Quellen suchen
```

Adoptierte Skills haben keinen Upstream: `installs/<name>` ist die einzige Kopie ihres
Inhalts. `remove` verlangt deshalb explizit `--prune`.

## Quellen

**Community-Registry** (`majiayu000/claude-skill-registry`) — statisches Artefakt auf
raw.githubusercontent.com, rund 160'000 Skills in 256 Shards. Einzige Quelle mit
**Beschreibung und Lizenz pro Skill**. Muss einmal lokal indexiert werden:

```sh
skill-tool index --refresh     # ~18 MB, ca. 5 s
skill-tool index               # Status, Alter, Anzahl
```

Danach ist die Suche offline und ohne Rate-Limit — rund 60 ms über alle 160k Records. Der
Index liegt in `$XDG_CACHE_HOME/skill-tool` bzw. `~/.cache/skill-tool` (43 MB) und ist
workspace-unabhängig. Upstream regeneriert etwa täglich.

**skills.sh** — `GET https://www.skills.sh/api/search?q=…`, keyless. Liefert `owner/repo` und
Skill-ID sowie Install-Zahlen, aber keine Beschreibung.

**GitHub Code-Search** — `filename:SKILL.md <query>`, liefert den exakten Pfad im Repo.
Braucht ein Token: `GITHUB_TOKEN` → `GH_TOKEN` → `gh auth token`. Ohne Token meldet die
Suche eine Warnung und liefert die übrigen Quellen. Die Repo-Beschreibung wird bewusst
*nicht* als Skill-Beschreibung angezeigt — sie beschreibt die Sammlung, nicht den Skill.

### Ranking

Die Listen werden per **Reciprocal Rank Fusion** zusammengeführt: nur die Position innerhalb
der jeweiligen Trefferliste zählt, nicht die absolute Zahl. Sonst würden die Install-Zahlen
von skills.sh (fünfstellig) jeden GitHub-Treffer (kein Popularitätssignal) verdrängen. Ein
Skill, den mehrere Quellen kennen, wandert nach oben.

Danach greift ein **Diversitäts-Cap von 3 Treffern pro Repository**. Aggregator-Repos
spiegeln hunderte Skills; ohne Cap belegte ein einziger Mirror 8 von 20 Zeilen und verdrängte
die Repos, aus denen die Skills tatsächlich stammen. Zurückgehaltene Zeilen füllen am Ende
auf, damit die Trefferzahl stimmt.

### Deduplizierung

Der Schlüssel ist `owner/repo/<verzeichnisname>`, nicht der volle Pfad — die Quellen
schreiben denselben Skill unterschiedlich (`swift-concurrency` vs. `skills/swift-concurrency`).
Beim Zusammenführen gewinnt die spezifischere Referenz, weil sie ohne Suche im Clone auflöst.

### Vor der Installation nachsehen

```sh
skill-tool info swiftui-pro                                      # installiert
skill-tool info avdlee/swift-testing-agent-skill/swift-testing-expert   # noch nicht
```

Bei installierten Skills kommt die Beschreibung aus dem SKILL.md-Frontmatter und ist
vollständig; dazu Quelle, Commit, Gruppen und der Verzeichnisinhalt. Bei nicht installierten
stammt sie aus dem Registry-Index und ist dort upstream auf 200 Zeichen gekürzt — für eine
Vorschau reicht das.

### Lizenzen

Die Registry klassifiziert jeden Skill (`license`, `distribution`). In der Suchausgabe steht
die Lizenz hinter der Popularität; `⚠ licence?` markiert `NOASSERTION` oder `restricted` —
also Skills, deren Lizenz GitHub nicht eindeutig zuordnen konnte. Für den Einsatz in
Kundenprojekten ist das vor der Installation relevant, nicht danach.

## Namenskollisionen

`installs/` ist flach, Skill-Verzeichnisnamen sind es nicht. Wenn zwei Repos denselben Namen
mitbringen, bricht `add` ab statt zu überschreiben:

```
Error: 'swiftui' is already installed from rshankras/claude-code-apple-skills/skills/swiftui;
majiayu000/claude-skill-registry-data/data/swiftui wants the same name.
Re-run with --as <name> — the usual convention is 'swiftui@<owner>'.
```

## Entwicklung

```sh
swift build
swift test
```

Die Logik liegt vollständig in `SkillToolKit`; `SkillToolCLI` ist nur Argument-Parsing und
Ausgabe.
