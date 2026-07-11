# Replay scenario schema (`sapdev.replay/1`)

A linear, hand-editable JSON scenario. `init` authors it from a /sap-gui-probe or
/sap-gui-skill-scaffold folder (steps + guards + popup branches pre-filled, checkpoints stubbed).

```jsonc
{
  "schema": "sapdev.replay/1",
  "name": "...", "tcode": "MM03",
  "recorded_release": "S4HANA_1909",   // compared to the live server_release_marker; mismatch = WARN
  "case_id": "MM03_DISPLAY",
  "steps": [
    {
      "action": { "id": "<findById path>", "verb": "set|press|select|sendVKey|ok-code", "value": "%%TOKEN%%" },
      "guard":  { "program": "SAPLMGMM", "dynpro": "0070", "timeout_s": 30 },   // expected screen AFTER the action
      "popups": [ { "discriminator": "wnd[1]/usr/...", "disposition": "fill|confirm|cancel" } ],
      "checkpoints": [
        { "type": "field",   "id": "<control>", "expected": "%%X%%" },
        { "type": "message", "expected_id": "M3", "expected_number": "816", "expected_type": "S", "capture": "TOKEN" },
        { "type": "table",   "table": "MARA", "field": "MATNR", "keyfield": "MATNR", "expected": "%%MATERIAL%%" }
      ]
    }
  ]
}
```

**Rules.** Actions/checkpoints are ALWAYS by control ID + VKey + message class/number/type - never
displayed text (language independence). `%%TOKEN%%` values come from `--data` bindings or a `capture`
in an earlier message checkpoint (`%%CAPTURE:TOKEN%%`). Exactly three checkpoint types in v1: field
(control value compare), message (status bar id/number/type, optionally captures a MessageParameter
into a token), table (post-step RFC_READ_TABLE key assertion). The compiler splits the steps at every
`table` checkpoint into GUI segments; the generic interpreter VBS runs any segment and the RFC engine
runs the table checks between segments. `lint` validates token coverage, guard completeness, the tcode
(TSTC), and every table checkpoint's (table,field) against live DDIC.
