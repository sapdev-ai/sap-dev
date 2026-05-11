"""Translation strings for build_spec_template.py.

Bilingual EN + JA dicts. Adding a third language (e.g. ZH) means adding a "ZH"
entry to every dict — no other code changes elsewhere.

DESIGN PRINCIPLE — stable vs. translated:
  * Section keys, output_file names, output_column names, format values,
    named-range names, and SAP-technical identifiers (MSG_CLASS, FIELDNAME,
    KEY, INITIAL, DATAELEMENT, TEXT_ID, MSG_TYPE, MSG_TEXT, etc.) stay in
    English in BOTH languages — they're the contract downstream skills consume.
  * Sheet names, sheet titles, banner notes, section banner labels, prose
    column headers, and README content translate per language.
"""

# ---------------------------------------------------------------------------
# T_SHEETS — the worksheet's tab name (.title)
# ---------------------------------------------------------------------------
T_SHEETS = {
    "EN": {
        "cover":        "Cover",
        "interface":    "Interface Contract",
        "validation":   "Validation Rules",
        "process":      "Processing Flow",
        "domains":      "Domains",
        "dataelements": "Data Elements",
        "tables":       "Tables",
        "errmsgs":      "Error Messages",
        "textels":      "Text Elements",
        "selscr":       "Selection Screen",
        "seldef":       "Selection Definition",
        "filemap_in":   "Mapping (File In)",
        "filemap_out":  "Mapping (File Out)",
        "supplement":   "Supplement",
        "golden":       "Golden Tests",
        "deps":         "Dependencies",
        "readme":       "README",
        "meta":         "(Meta) Layout",
    },
    "JA": {
        "cover":        "表紙",
        "interface":    "インターフェース契約",
        "validation":   "検証ルール",
        "process":      "処理フロー",
        "domains":      "ドメイン",
        "dataelements": "データエレメント",
        "tables":       "テーブル",
        "errmsgs":      "エラーメッセージ",
        "textels":      "テキストエレメント",
        "selscr":       "選択画面レイアウト",
        "seldef":       "選択画面項目定義",
        "filemap_in":   "ファイルマッピング (受信)",
        "filemap_out":  "ファイルマッピング (送信)",
        "supplement":   "補足",
        "golden":       "ゴールデンテスト",
        "deps":         "依存関係",
        "readme":       "README",
        "meta":         "(Meta) Layout",
    },
}


# ---------------------------------------------------------------------------
# T_TITLES — row-1 title text on each content sheet
# ---------------------------------------------------------------------------
T_TITLES = {
    "EN": {
        "cover":        "Cover — Program Summary",
        "interface":    "Interface Contract — Inputs / Outputs / Exceptions",
        "validation":   "Validation Rules",
        "process":      "Processing Flow",
        "domains":      "Domains",
        "dataelements": "Data Elements",
        "tables":       "Tables — Metadata + Fields (joined by Table)",
        "errmsgs":      "Error Messages",
        "textels":      "Text Elements",
        "selscr":       "Selection Screen Layout — paste a whole-screen image below",
        "seldef":       "Selection Definition — one row per selection-screen field",
        "filemap_in":   "Mapping (File In) — file field → SAP table.field",
        "filemap_out":  "Mapping (File Out) — SAP table.field → file field (future use)",
        "supplement":   "Supplement — free-form notes for the developer",
        "golden":       "Golden Tests",
        "deps":         "Dependencies — FMs, BAPIs, Includes",
        "readme":       "How to fill in this template",
        "meta":         "(Meta) Layout — managed by /sap-docs-layout. Do not edit by hand.",
    },
    "JA": {
        "cover":        "表紙 — プログラム概要",
        "interface":    "インターフェース契約 — 入力 / 出力 / 例外",
        "validation":   "検証ルール",
        "process":      "処理フロー",
        "domains":      "ドメイン",
        "dataelements": "データエレメント",
        "tables":       "テーブル — メタデータ + フィールド (Table 列で結合)",
        "errmsgs":      "エラーメッセージ",
        "textels":      "テキストエレメント",
        "selscr":       "選択画面レイアウト — 画面全体の画像を以下に貼り付けてください",
        "seldef":       "選択画面項目定義 — 選択画面の項目ごとに 1 行",
        "filemap_in":   "ファイルマッピング (受信) — ファイル項目 → SAP テーブル.項目",
        "filemap_out":  "ファイルマッピング (送信) — SAP テーブル.項目 → ファイル項目 (将来利用)",
        "supplement":   "補足 — 開発者向けの自由記述メモ",
        "golden":       "ゴールデンテスト",
        "deps":         "依存関係 — FM、BAPI、インクルード",
        "readme":       "このテンプレートの記入方法",
        "meta":         "(Meta) Layout — /sap-docs-layout が管理するシートです。手動で編集しないでください。",
    },
}


# ---------------------------------------------------------------------------
# T_BANNER — yellow instruction banners under sheet titles
# ---------------------------------------------------------------------------
T_BANNER = {
    "EN": {
        "cover":        "Fill in one row per field. Don't add or remove rows above row 4.",
        "domains":      "One row per DDIC domain. Headers locked at row 3.",
        "dataelements": "One row per DDIC data element. Domain name in column C must exist on the Domains sheet (or be a primitive type).",
        "selscr":       "Paste a single image of the WHOLE selection screen below (Insert → Picture). /sap-docs-extract saves it as _selection_screen_layout.png. /sap-gen-abap reads the image for layout hints; the parameter list comes from Selection Definition.",
        "seldef":       "One row per selection-screen field. Mandatory: ● = required, ○ = optional, △ = conditional.",
        "filemap_in":   "One row per file column. Mandatory (create/update): ● = required, ○ = optional, △ = conditional, × = fixed (no input).",
        "filemap_out":  "Skeleton for outbound mapping (ABAP → file). Same column structure as Mapping (File In). Customer fills when an outbound interface is in scope.",
        "supplement":   "Free-form notes for the developer: edge cases, business context, glossary, decision rationale, anything that doesn't fit the other sheets. /sap-docs-extract dumps this whole sheet verbatim as _supplement.txt; /sap-gen-abap reads it as low-priority context.",
    },
    "JA": {
        "cover":        "1 項目につき 1 行入力してください。4 行目より上の行は追加・削除しないでください。",
        "domains":      "DDIC ドメインごとに 1 行入力してください。3 行目のヘッダーは固定です。",
        "dataelements": "DDIC データエレメントごとに 1 行入力してください。C 列のドメイン名はドメインシートに存在するか、プリミティブ型である必要があります。",
        "selscr":       "選択画面全体の画像を 1 枚、以下に貼り付けてください (挿入 → 画像)。/sap-docs-extract が _selection_screen_layout.png として保存します。/sap-gen-abap はレイアウトヒントとして画像を読みます。項目一覧は選択画面項目定義シートから取得されます。",
        "seldef":       "選択画面の項目ごとに 1 行入力してください。必須入力: ● = 必須、○ = 任意、△ = 条件付き。",
        "filemap_in":   "ファイルの項目ごとに 1 行入力してください。必須入力 (登録/更新): ● = 必須、○ = 任意、△ = 条件付き、× = 固定 (入力不可)。",
        "filemap_out":  "送信マッピング (ABAP → ファイル) のスケルトン。ファイルマッピング (受信) と同じ列構造です。送信インターフェースが必要になった際に記入してください。",
        "supplement":   "開発者向けの自由記述メモ: エッジケース、業務背景、用語集、設計判断の理由など、他のシートに収まらない内容を記入してください。/sap-docs-extract がシート全体をそのまま _supplement.txt として出力し、/sap-gen-abap が補助情報として参照します。",
    },
}


# ---------------------------------------------------------------------------
# T_SECTION_BANNERS — blue sub-section headers within a sheet
# ---------------------------------------------------------------------------
T_SECTION_BANNERS = {
    "EN": {
        "iface_inputs":     "Inputs",
        "iface_outputs":    "Outputs",
        "iface_exceptions": "Exceptions",
        "tables_metadata":  "Metadata — one row per table",
        "tables_fields":    "Fields — one row per field; Table links to Metadata",
    },
    "JA": {
        "iface_inputs":     "入力",
        "iface_outputs":    "出力",
        "iface_exceptions": "例外",
        "tables_metadata":  "メタデータ — テーブルごとに 1 行",
        "tables_fields":    "フィールド — フィールドごとに 1 行。Table 列でメタデータと結合します",
    },
}


# ---------------------------------------------------------------------------
# T_HEADERS — column headers for each section's data block
#
# Indexed by SECTION KEY (matches keys used in (Meta) Layout SECTIONS_ROWS).
# SAP-technical identifiers (FIELDNAME, KEY, INITIAL, DATAELEMENT, MSG_CLASS,
# MSG_NO, MSG_TYPE, MSG_TEXT, TEXT_ID, TEXT_VALUE) intentionally kept stable
# across languages — they match what customers see in SE91 / SE11 / SE38.
# ---------------------------------------------------------------------------
T_HEADERS = {
    "EN": {
        "cover":              ["FIELD", "VALUE", "", ""],
        "iface_inputs":       ["NAME", "TYPE", "LENGTH", "DESCRIPTION"],
        "iface_outputs":      ["NAME", "TYPE", "LENGTH", "DESCRIPTION"],
        "iface_exceptions":   ["MSG_CLASS", "MSG_NO", "WHEN_RAISED", "ACTION"],
        "validation":         ["No", "Field", "Rule Description", "Error Message Ref"],
        "process":            ["Step", "Action", "Notes"],
        "domains":            ["Domain name", "Short description", "Data type", "Length", "Decimals",
                               "Sign", "Lowercase", "Output length", "Conversion routine"],
        "dataelements":       ["Data element name", "Short description", "Domain name",
                               "Label (short)", "Label (medium)", "Label (long)", "Label (heading)"],
        "tables_metadata":    ["Table name", "Short description", "Delivery class", "Data class",
                               "Size category", "", "", ""],
        "tables_fields":      ["Table", "No", "FIELDNAME", "KEY", "INITIAL", "DATAELEMENT",
                               "ReferenceTable", "Ref.Field"],
        "errmsgs":            ["MSG_CLASS", "MSG_NO", "MSG_TYPE", "MSG_TEXT"],
        "textels":            ["TEXT_ID", "TEXT_VALUE"],
        # Image format — no header row. Empty list signals "no columns".
        "selscr":             [],
        "seldef":             ["No", "Field label", "Field name (Japanese)", "Field name (English)",
                               "Data element name", "Data type", "Length (integer)", "Length (decimals)",
                               "I/O type", "Display format", "Mandatory", "Description", "Default value"],
        # filemap headers shared by filemap_in and filemap_out (same column
        # structure; outbound currently used as a forward-looking skeleton).
        "filemap":            ["No.", "File field", "Data type", "Length",
                               "Mandatory (create)", "Mandatory (update)", "Notes",
                               "SAP table", "SAP field"],
        # Text format — no header row. Customer writes free-form text.
        "supplement":         [],
        "golden":             ["Test ID", "Scenario", "Inputs", "Expected Output", "Notes"],
        "deps":               ["Type", "Name", "Purpose", "Notes"],
    },
    "JA": {
        "cover":              ["項目", "値", "", ""],
        "iface_inputs":       ["名称", "型", "長さ", "説明"],
        "iface_outputs":      ["名称", "型", "長さ", "説明"],
        "iface_exceptions":   ["MSG_CLASS", "MSG_NO", "発生条件", "対処"],
        "validation":         ["No", "フィールド", "ルール説明", "エラーメッセージ参照"],
        "process":            ["ステップ", "アクション", "備考"],
        "domains":            ["ドメイン名", "短い説明", "データ型", "長さ", "小数点以下",
                               "符号", "小文字許可", "出力長", "変換ルーチン"],
        "dataelements":       ["データエレメント名", "短い説明", "ドメイン名",
                               "ラベル (短)", "ラベル (中)", "ラベル (長)", "ラベル (見出し)"],
        "tables_metadata":    ["テーブル名", "短い説明", "受渡クラス", "データクラス",
                               "サイズカテゴリ", "", "", ""],
        "tables_fields":      ["テーブル", "No", "FIELDNAME", "KEY", "INITIAL", "DATAELEMENT",
                               "参照テーブル", "参照フィールド"],
        "errmsgs":            ["MSG_CLASS", "MSG_NO", "MSG_TYPE", "MSG_TEXT"],
        "textels":            ["TEXT_ID", "TEXT_VALUE"],
        "selscr":             [],
        "seldef":             ["No", "項目ラベル", "項目名 (日本語)", "項目名 (英字)",
                               "データタイプ名", "データ型", "桁数 (整数部)", "桁数 (小数部)",
                               "入出力種別", "表示形式", "必須入力", "説明", "デフォルト値"],
        "filemap":            ["No.", "ファイル項目", "データタイプ", "長さ",
                               "必須入力 (登録)", "必須入力 (更新)", "備考",
                               "SAP テーブル", "SAP 項目"],
        "supplement":         [],
        "golden":             ["テスト ID", "シナリオ", "入力", "期待される出力", "備考"],
        "deps":               ["種別", "名称", "用途", "備考"],
    },
}


# ---------------------------------------------------------------------------
# T_KEYWORDS — anchor keyword stored in the (Meta) Layout SECTIONS table.
# Must match the FIRST cell of the header row on the actual data sheet, so
# the parser's keyword-fallback can find the section without named ranges.
# ---------------------------------------------------------------------------
T_KEYWORDS = {
    "EN": {
        "cover":             "FIELD",
        "iface_inputs":      "NAME",
        "iface_outputs":     "NAME",
        "iface_exceptions":  "MSG_CLASS",
        "validation":        "No",
        "process":           "Step",
        "domains":           "Domain name",
        "dataelements":      "Data element name",
        "tables_metadata":   "Table name",
        "tables_fields":     "FIELDNAME",
        "errmsgs":           "MSG_CLASS",
        "textels":           "TEXT_ID",
        "selscr":            "",          # image format — no anchor keyword
        "seldef":            "No",
        "filemap_in":        "No.",
        "filemap_out":       "No.",
        "supplement":        "",          # text format — no anchor keyword
        "golden":            "Test ID",
        "deps":              "Type",
    },
    "JA": {
        "cover":             "項目",
        "iface_inputs":      "名称",
        "iface_outputs":     "名称",
        "iface_exceptions":  "MSG_CLASS",
        "validation":        "No",
        "process":           "ステップ",
        "domains":           "ドメイン名",
        "dataelements":      "データエレメント名",
        "tables_metadata":   "テーブル名",
        "tables_fields":     "FIELDNAME",
        "errmsgs":           "MSG_CLASS",
        "textels":           "TEXT_ID",
        "selscr":            "",
        "seldef":            "No",
        "filemap_in":        "No.",
        "filemap_out":       "No.",
        "supplement":        "",
        "golden":            "テスト ID",
        "deps":              "種別",
    },
}


# ---------------------------------------------------------------------------
# T_COVER_LABELS — column-A labels on the Cover sheet (rows 4–12).
# These ARE the field names in _PGM_summary.txt, so translating them changes
# the output keys. Acceptable because each customer file only ever runs in
# one language; the parser uses col-A text directly as TSV keys.
#
# NOTE: If you want stable output keys across languages (recommended for
# pipelines that mix EN / JA specs), keep these in English and only translate
# the surrounding chrome (title, banner). For now we translate them — keeps
# the customer-facing UI consistent.
# ---------------------------------------------------------------------------
T_COVER_LABELS = {
    "EN": [
        "Function ID", "Function spec name", "Program ID", "Program name",
        "Program type", "Package", "Function group", "System number",
        "ABAP version",
    ],
    "JA": [
        "機能 ID", "機能仕様名", "プログラム ID", "プログラム名",
        "プログラム種別", "パッケージ", "ファンクショングループ", "システム番号",
        "ABAP バージョン",
    ],
}


# ---------------------------------------------------------------------------
# T_README — README sheet content, one entry per row.
# ---------------------------------------------------------------------------
T_README = {
    "EN": [
        "",
        "1. Start with the Cover sheet — fill in Function ID, Program ID, Package, etc.",
        "2. Define DDIC objects on the Domains, Data Elements, and Tables sheets.",
        "3. Describe inputs / outputs / exceptions on the Interface Contract sheet.",
        "4. Paste the selection-screen image on the Selection Screen sheet, and",
        "   list each field on the Selection Definition sheet.",
        "5. Map file columns to SAP table.field on the Mapping (File In) sheet.",
        "   Use Mapping (File Out) when an outbound interface is in scope.",
        "6. List validation rules and processing flow on their respective sheets.",
        "7. Capture error messages and selection-screen text elements.",
        "8. Add at least one golden test scenario before handing off for generation.",
        "9. Run /sap-docs-extract <this file> to produce the structured _*.txt files.",
        "",
        "DON'T edit the (Meta) Layout sheet by hand — use /sap-docs-layout. The",
        "Meta sheet describes how the parser maps each sheet to an output file.",
        "If you need to add columns, rename sheets, or localize headers, run:",
        "  /sap-docs-layout add-column   <this file> ...",
        "  /sap-docs-layout rename-sheet <this file> ...",
        "  /sap-docs-layout validate     <this file>",
    ],
    "JA": [
        "",
        "1. 表紙シートから始めてください — 機能 ID、プログラム ID、パッケージなどを記入します。",
        "2. DDIC オブジェクトをドメイン、データエレメント、テーブルの各シートに定義します。",
        "3. 入力 / 出力 / 例外をインターフェース契約シートに記載します。",
        "4. 選択画面レイアウトシートに画面全体の画像を貼り付け、選択画面項目定義シートに",
        "   各項目を記入します。",
        "5. ファイルマッピング (受信) シートでファイル項目を SAP テーブル.項目にマップします。",
        "   送信インターフェースが必要な場合は、ファイルマッピング (送信) シートを使用します。",
        "6. 検証ルールと処理フローをそれぞれのシートに記入します。",
        "7. エラーメッセージと選択画面のテキストエレメントを記録します。",
        "8. 生成前に最低 1 つのゴールデンテストシナリオを追加してください。",
        "9. /sap-docs-extract <このファイル> を実行して構造化された _*.txt ファイルを生成します。",
        "",
        "(Meta) Layout シートを手動で編集しないでください — /sap-docs-layout を使用してください。",
        "Meta シートはパーサーが各シートを出力ファイルにマップする方法を記述します。",
        "列の追加、シート名の変更、ヘッダーのローカライズが必要な場合は、以下を実行してください:",
        "  /sap-docs-layout add-column   <このファイル> ...",
        "  /sap-docs-layout rename-sheet <このファイル> ...",
        "  /sap-docs-layout validate     <このファイル>",
    ],
}


# ---------------------------------------------------------------------------
# Convenience: list of supported language codes (single source of truth)
# ---------------------------------------------------------------------------
SUPPORTED_LANGS = sorted(T_SHEETS.keys())


def get_lang_strings(lang: str) -> dict:
    """Return a single dict bundling every translation set for the chosen language.

    Raises KeyError with a helpful message if any per-language dict is missing
    the requested LANG — this is the build-time guard against "I added EN
    but forgot JA."
    """
    if lang not in SUPPORTED_LANGS:
        raise SystemExit(
            f"Unsupported --lang {lang}. Use one of: {', '.join(SUPPORTED_LANGS)}"
        )
    bundle = {
        "S":           T_SHEETS[lang],
        "T":           T_TITLES[lang],
        "B":           T_BANNER[lang],
        "SB":          T_SECTION_BANNERS[lang],
        "H":           T_HEADERS[lang],
        "K":           T_KEYWORDS[lang],
        "COVER_LBL":   T_COVER_LABELS[lang],
        "README":      T_README[lang],
    }
    return bundle
