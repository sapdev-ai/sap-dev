# SAP GUI Script Recording Skill

Guides users to discover SAP GUI component IDs via the built-in Script Recording
and Playback feature, then parses the recorded VBS file to extract and decode
component IDs, actions, and values. Includes a comprehensive SAP GUI Scripting
API quick reference.

## Skill Overview

This skill helps users discover SAP GUI component IDs for automation:

- **Recording Guidance**: Step-by-step instructions to use SAP GUI's built-in Script Recording and Playback
- **VBS Parsing**: Reads recorded VBS files and extracts all `session.findById(...)` lines
- **Component Decoding**: Identifies component types from ID path prefixes (ctxt, txt, btn, rad, etc.)
- **API Reference**: Comprehensive inline reference for VKey codes, shell methods, toolbar positions
- **No SAP Login Required**: User is already logged in when recording — no credentials needed
- **No VBS Templates**: Uses SAP GUI's built-in recorder — no custom scripts

## Auto-Trigger Keywords

This skill activates when discussing:

### Component ID Discovery
- component ID, findById, element ID, screen element
- field ID, button ID, tab ID, control ID
- which field, what ID, how to find ID

### Script Recording
- Script Recording, Scripting Recorder, record SAP
- Record and Playback, SAP recording, VBS recording
- record script, recorded VBS, recording file

### SAP GUI Scripting API
- SAP GUI Scripting, GuiSession, GuiApplication
- sendVKey, VKey code, virtual key
- doubleClick, press, select, getText
- GuiShell, GuiTextField, GuiButton, GuiCTextField
- getCellValue, getLineText, RowCount

### Troubleshooting Other Skills
- menu path not working, component ID mismatch
- findById failed, element not found
- wrong component ID, screen changed

## Directory Structure

```
sap-gui-record/
├── SKILL.md      # Main skill file (workflow + API reference)
└── README.md     # This file (keywords for discoverability)
```

## Usage

Invoke to discover component IDs or look up API details:

- "How do I find the component ID for a field in SE11?"
- "Parse my recording at {WORK_TEMP}\sap_recording.vbs"
- "What VKey code is F8?"
- "What is the component type prefix for a checkbox?"
- "The menu path in sap-se37 doesn't work on my system"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- Already logged into SAP (this skill does not handle login)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-08

## License

GPL-3.0 License - See LICENSE file in repository root.
