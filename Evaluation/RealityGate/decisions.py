"""LocalFlow experiment questions. Only categorical decisions, never generated slots."""
from build_corpus import INTENTS

DESCRIPTIONS = [
    "Speech to be written, narrative, quotation, negation or hypothetical instruction, not an instruction to execute.",
    "Start or open an application.", "Bring an already running application to the front.",
    "Quit or close an application.", "Visit a URL, domain or saved website alias.",
    "Search the web or a search provider for a query.", "Create, append or write a note.",
    "Create a reminder.", "Control music playback or media.", "Change volume, mute, lock or sleep the display.",
    "Type, copy or replace exact text.", "Reveal a file or saved folder/project.",
    "Execute a saved macro or a sentence containing multiple distinct commands.",
    "Unsupported request or a prefix that has not yet specified an intent.",
]
QUESTIONS = {
    "intent": {"type": "choice", "instructions": "Classify the requested LocalFlow Mac operation. Quoted or negated instructions are dictation. Choose one category; never output payloads.",
               "criteria": dict(zip(INTENTS, DESCRIPTIONS))},
    "risk": {"type": "choice", "instructions": "Classify the highest risk of executing this speech. Narration has no effects. Opening/focusing apps, creating notes/reminders and copying/typing are reversible. Quitting apps, replacing selections, changing existing notes, locking/sleeping and saved macros require confirmation. Unsupported destructive or externally consequential requests are consequential.",
             "criteria": {"safe": "Read-only navigation/search/reveal or no requested effect.",
                          "reversible": "Bounded new or reversible effect.",
                          "consequential": "Requires confirmation; may lose/overwrite existing state, run unknown macro steps or have irreversible/external effects."}},
    "more_speech": {"type": "noul", "instructions": "Is more speech required to complete the request or sentence? A complete streaming prefix does not need more speech just because is_final is false. Trailing conjunctions, incomplete targets/payloads and unresolved corrections need more speech.", "criteria": {}},
    "command": {"type": "noul", "instructions": "Is the speaker instructing an action now (including unsupported requests), rather than narrating, quoting, negating or hypothetically discussing commands? Typing quoted command words is still a text command.", "criteria": {}},
    "ambiguous": {"type": "noul", "instructions": "Is there unresolved ambiguity about the application, target, payload or supported action? Missing aliases, homophones and unsupported requests are ambiguous. A completed explicit correction to a unique target is not ambiguous.", "criteria": {}},
}

def options(question):
    return list(question["criteria"]) if question["type"] == "choice" else [False, True]
