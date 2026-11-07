#!/usr/bin/env python3
"""Builds the two shortcuts Perch uses to drive Apple's Focus, into Resources/:

  Perch Focus      input: a Focus name ("Do Not Disturb", "Work", ...). Prints the Focus that
                   was on ("" for none), then turns the named Focus on until turned off.
  Perch Focus Off  Prints the Focus that was on, then turns Do Not Disturb off.

macOS has no public API for turning Focus on or off, but Shortcuts does; Perch runs these with
`shortcuts run <name> -i <file> -o -`. Both are straight lines of actions with no If steps:
generated If steps don't load on current Shortcuts.

Usage: scripts/focus-shortcut.py   (signs with `shortcuts sign --mode anyone`, which needs
an iCloud-signed-in Mac and the network; the signed files carry no personal details)
"""
import os
import plistlib
import subprocess
import sys
import tempfile
import uuid


def U():
    return str(uuid.uuid4()).upper()


def var(u, name):
    return {"Value": {"OutputUUID": u, "Type": "ActionOutput", "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}


def text(u, name):
    return {"Value": {"string": "￼",
                      "attachmentsByRange": {"{0, 1}": {"OutputUUID": u, "Type": "ActionOutput", "OutputName": name}}},
            "WFSerializationType": "WFTextTokenString"}


INPUT = {"Value": {"Type": "ExtensionInput"}, "WFSerializationType": "WFTextTokenAttachment"}
DND = {"Identifier": "com.apple.donotdisturb.mode.default", "DisplayString": "Do Not Disturb"}


def act(identifier, **params):
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": params}


def output(u):
    return act("is.workflow.actions.output", WFOutput=text(u, "Focus"), WFResponse=text(u, "Focus"))


def workflow(actions):
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2607.0.3",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
        "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
    }


on_before, off_before = U(), U()
shortcuts = {
    "Perch Focus": workflow([
        act("is.workflow.actions.dnd.getfocus", UUID=on_before),
        act("is.workflow.actions.dnd.set", Operation="Turn", Enabled=1, FocusModes=INPUT, AssertionType="Turned Off"),
        output(on_before),
    ]),
    "Perch Focus Off": workflow([
        act("is.workflow.actions.dnd.getfocus", UUID=off_before),
        act("is.workflow.actions.dnd.set", Operation="Turn", Enabled=0, FocusModes=DND),
        output(off_before),
    ]),
}

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with tempfile.TemporaryDirectory() as tmp:
    for name, wf in shortcuts.items():
        unsigned = os.path.join(tmp, f"{name}.shortcut")
        out = os.path.join(root, "Resources", f"{name}.shortcut")
        with open(unsigned, "wb") as f:
            plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)
        r = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", out],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not os.path.exists(out):
            sys.exit(f"signing {name} failed: {r.stderr.strip()}")
        print(f"wrote {out}")
