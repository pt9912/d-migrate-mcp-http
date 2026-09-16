#!/usr/bin/env python3
"""Vergleicht den Quell-Katalog mit dem neutralen Modell und meldet stille
Typverluste beim Reverse.

Aufruf:  silent-loss-check.py <native_types_datei> <neutral_artifact_datei>

native_types_datei: Zeilen "<spalte>|<quelltyp>"
neutral_artifact_datei: das YAML-Reverse-Artefakt

Gemeldet wird eine Spalte, wenn
  a) das neutrale Modell text/char fuehrt, der Quelltyp aber kein Text-Typ ist
     (z.B. MSSQL rowversion/sql_variant, PG interval, Oracle ROWID), ODER
  b) das neutrale Modell enum mit ref_type fuehrt, zu dem es KEINEN
     custom_types-Eintrag gibt (PostGIS geography als Enum fehlgelesen), ODER
  c) das neutrale Modell die Spalte GAR NICHT fuehrt (der Reader hat sie
     verloren) — diese Klasse ist fuer den Quell<->Ziel-Vergleich prinzipiell
     unsichtbar, weil beide Seiten aus demselben Reverse stammen.

Ausgabe: "<spalte>|<quelltyp>|<neutraltyp>" je Fund.

Der YAML-Scanner arbeitet mit relativen Einrueckungen (kein YAML-Parser auf
der Platte, und feste Spaltenbreiten waeren bei Format-Drift still falsch).
"""
import re
import sys

TEXT_FAMILY = {
    'char', 'character', 'bpchar', 'varchar', 'character varying', 'nchar',
    'nvarchar', 'nvarchar2', 'varchar2', 'text', 'tinytext', 'mediumtext',
    'longtext', 'ntext', 'clob', 'nclob', 'string', 'long', 'citext', 'name',
}

KEY_RE = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*):\s*$')
ATTR_RE = re.compile(r'^(\s*)(type|ref_type):\s*(\S+)\s*$')


def norm(t: str) -> str:
    """Laengenangaben abschneiden, damit 'char(8)' als Text-Familie erkannt
    wird ('char'), 'bit(8)' aber nicht ('bit')."""
    return re.sub(r'\(.*', '', t.strip().lower()).strip()


def parse_model(path: str):
    """Liefert (columns, custom_types) aus dem Artefakt.

    columns: {spalte: {'type': ..., 'ref_type': ...}} der Tabelle type_matrix
    """
    section = None
    section_indent = None
    table = None
    table_indent = None
    in_columns = False
    columns_indent = None
    col = None
    columns, custom_types = {}, set()

    for raw in open(path):
        line = raw.rstrip('\n')
        m = KEY_RE.match(line)
        a = ATTR_RE.match(line)
        if m:
            indent, name = len(m.group(1)), m.group(2)
            if section is None or (section_indent is not None and indent <= section_indent):
                # neue Top-Level-Sektion
                section, section_indent = name, indent
                table = table_indent = None
                in_columns, columns_indent, col = False, None, None
                continue
            if section == 'custom_types':
                custom_types.add(name.lower())
                continue
            if section == 'tables':
                if table_indent is None:
                    table_indent = indent
                if indent == table_indent:
                    table = name
                    in_columns, columns_indent, col = False, None, None
                    continue
                if table == 'type_matrix':
                    if name == 'columns':
                        in_columns, columns_indent = True, indent
                        continue
                    if in_columns and (columns_indent is None or indent > columns_indent):
                        col = name.lower()
                        columns.setdefault(col, {})
                        continue
            if section == 'tables' and table == 'type_matrix' and in_columns and indent > (columns_indent or 0):
                # verschachtelter Block einer Spalte (z. B. generation:) — ignorieren
                continue
            continue
        if a and section == 'tables' and table == 'type_matrix' and col:
            indent, key, val = len(a.group(1)), a.group(2), a.group(3)
            if columns_indent is not None and indent > columns_indent:
                columns[col][key] = val.strip().lower()
    return columns, custom_types


def main() -> int:
    native = {}
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line or '|' not in line:
            continue
        col, typ = line.split('|', 1)
        col, typ = col.strip().lower(), typ.strip()
        if col and typ:
            native[col] = typ

    columns, custom_types = parse_model(sys.argv[2])

    # c) Spalte fehlt im Modell — der schwerste Fall, in beiden Achsen unsichtbar
    for col, src in sorted(native.items()):
        if col not in columns:
            if col == 'id':
                continue  # Identitaetsspalte wird je Dialekt anders modelliert
            print(f'{col}|{src}|FEHLT IM MODELL')

    for col, attrs in sorted(columns.items()):
        base = attrs.get('type', '')
        ref = attrs.get('ref_type', '')
        src = native.get(col, '')
        src_norm = norm(src)
        if base in ('text', 'char') and src and src_norm not in TEXT_FAMILY:
            print(f'{col}|{src}|{base}')
        elif base == 'enum' and ref and ref not in custom_types:
            print(f'{col}|{src}|enum(ref:{ref}, kein custom_type)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
