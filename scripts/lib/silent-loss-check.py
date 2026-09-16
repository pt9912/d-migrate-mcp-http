#!/usr/bin/env python3
"""Vergleicht den Quell-Katalog mit dem neutralen Modell und meldet stille
Typverluste beim Reverse.

Aufruf:  silent-loss-check.py <native_types_datei> <neutral_artifact_datei>

native_types_datei: Zeilen "<spalte>|<quelltyp>"
neutral_artifact_datei: das YAML-Reverse-Artefakt (Zeilen-Scanner, kein YAML-Parser)

Gemeldet wird eine Spalte, wenn
  a) das neutrale Modell text/char fuehrt, der Quelltyp aber kein Text-Typ ist
     (z.B. MSSQL rowversion/sql_variant, PG interval, Oracle ROWID), ODER
  b) das neutrale Modell enum mit ref_type fuehrt, zu dem es KEINEN
     custom_types-Eintrag gibt (PostGIS geography als Enum fehlgelesen).

Ausgabe: "<spalte>|<quelltyp>|<neutraltyp>" je Fund.
"""
import re
import sys

TEXT_FAMILY = {
    'char', 'character', 'bpchar', 'varchar', 'character varying', 'nchar',
    'nvarchar', 'nvarchar2', 'varchar2', 'text', 'tinytext', 'mediumtext',
    'longtext', 'ntext', 'clob', 'nclob', 'string', 'long', 'citext', 'name',
}


def norm(t: str) -> str:
    """Laengenangaben abschneiden, damit 'char(8)' als Text-Familie erkannt
    wird ('char'), 'bit(8)' aber nicht ('bit')."""
    t = re.sub(r'\(.*', '', t.strip().lower()).strip()
    return t


def main() -> int:
    native = {}
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line or '|' not in line:
            continue
        col, typ = line.split('|', 1)
        native[col.strip().lower()] = typ.strip()

    neutral, custom_types, section, table, column = {}, set(), None, None, None
    for raw in open(sys.argv[2]):
        line = raw.rstrip('\n')
        indent = len(line) - len(line.lstrip(' '))
        s = line.strip()
        if indent == 0 and s.endswith(':'):
            section, table, column = s[:-1], None, None
            continue
        if indent == 2 and s.endswith(':') and section in ('custom_types', 'tables'):
            if section == 'custom_types':
                custom_types.add(s[:-1].lower())
            else:
                table = s[:-1] if s[:-1] == 'type_matrix' else None
            continue
        if table and indent == 4 and s == 'columns:':
            continue
        if table and indent == 6 and s.endswith(':'):
            column = s[:-1].lower()
            continue
        if table and column and indent == 8 and s.startswith('type:'):
            neutral[column] = s.split(':', 1)[1].strip().lower()
        if table and column and indent == 8 and s.startswith('ref_type:'):
            ref = s.split(':', 1)[1].strip().lower()
            neutral[column] = neutral.get(column, '') + f'|ref:{ref}'

    for col, ntyp in sorted(neutral.items()):
        base, _, ref = ntyp.partition('|ref:')
        src = native.get(col, '')
        src_norm = norm(src)
        if base in ('text', 'char') and src and src_norm not in TEXT_FAMILY:
            print(f'{col}|{src}|{base}')
        elif base == 'enum' and ref and ref not in custom_types:
            print(f'{col}|{src}|enum(ref:{ref}, kein custom_type)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
