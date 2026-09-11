# Pilcrow

![Pilcrow icon](App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png)


Pilcrow is a plain-text editor for iPad and iPhone, requiring iPadOS or iOS 27 or later.

## Main functions

- Choose **Settings → Editor → New Windows and Tabs** to set **New Windows Open With** and **New Tabs Open With** separately to **Start Page** or **Blank Document**. The defaults remain Start Page for windows and Blank Document for tabs. Restored work keeps its contents; closing the last tab still returns to the start page.
- Use multiple windows. Each window can contain multiple tabs. On iPad, **Settings → Editor → Window Layout → Document Tabs** chooses a tab bar or a document list on the left. Narrow windows open that list with the **Documents** button.
- Use the command palette to browse, find, and run editor commands.
- Open the file browser, multi-file search, settings, and Markdown preview in separate windows.

## New window options

When you create a window, you can:

- Start with a blank document.
- Open an existing file.
- Start with text from the clipboard.
- Create a document from a template.

## Saving and restoration

Pilcrow’s tab-close commands use **Save / Don’t Save / Cancel** when exactly one document has unsaved changes, even if other clean tabs are also closing. With multiple unsaved documents, they show a checklist. **Close Window** uses the checklist for any number of unsaved documents, including one. All documents are selected initially. **Save All** (or **Save Selected** when some are unchecked) saves checked documents and discards unchecked changes only after every selected save succeeds. Untitled documents get their own filename and location picker. Canceling either confirmation or a file picker, or encountering a save error, keeps all affected tabs open; files already saved stay saved. **Don’t Save** discards unsaved changes without changing the original files. Documents without unsaved changes close immediately.

The iPad system window-close dialog offers **Review Changes…** and **Don’t Save**. **Review Changes…** keeps the window open and opens the document checklist. Pilcrow’s own **Close Window** command opens that checklist directly. The system’s preliminary confirmation remains part of the native window-close flow.

**Save All and Close Window**, available in the Window menu and command palette on iPad, skips the checklist. It saves every changed document in that window in tab order, including pinned and inactive tabs, asking for a destination for each untitled document. It closes the window only after all saves succeed. Canceling any picker or encountering a save error keeps the window and all its tabs open; completed saves remain saved. Other windows are unaffected.

Pilcrow keeps private recovery checkpoints while you work and restores your open windows and tabs after an interrupted session. These checkpoints do not save changes to the original files. A crash can lose edits made after the last completed checkpoint.

If previous work cannot be reopened automatically, the new-tab screen offers **Recover Unsaved Changes…**. This also provides access to unsaved work kept by older versions; it is absent when there is nothing left to recover.

## Licensing

| Component | Source | License |
|---|---|---|
| `EditorEngine` | [simonbs/Runestone](https://github.com/simonbs/Runestone) — © 2021 Simon Støvring | MIT |
| `FileEncoding`, `LineEnding`, `LineSort`, `CharacterInfo`, `StringUtils`, `ValueRange` | [coteditor/CotEditor](https://github.com/coteditor/CotEditor) — © 2005–2009 nakamuxu, © 2011, 2014 usami-k, © 2013–2026 1024jp | Apache 2.0 |
| tree-sitter and language grammars | [tree-sitter](https://github.com/tree-sitter) | MIT |
| App icon | Original project artwork | All rights reserved |

Full attribution and preserved upstream LICENSE text: see `NOTICE.md` and `Packages/EditorKit/LICENSE-EditorCore` / `LICENSE-Runestone`.
