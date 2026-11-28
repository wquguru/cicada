import Foundation

struct NoteEdit: Equatable {
    enum Target: Equatable {
        case summary
        case item(Int)
    }
    let session: String
    let target: Target
}

struct NotesEditHooks {
    let current: NoteEdit.Target?
    let open: (NoteEdit.Target?) -> Void
    let save: (NoteEdit.Target, String, String??) -> Void
}

extension MeetingNotes {
    func editing(_ target: NoteEdit.Target, text: String, owner: String?? = nil) -> MeetingNotes {
        var n = self
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func apply(_ item: inout NoteItem) {
            item.text = text
            if let owner { item.owner = owner.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        }
        switch target {
        case .summary:
            n.summary = text
        case .item(let i):
            let c = n.conclusions.count
            if i >= 0, i < c {
                if text.isEmpty { n.conclusions.remove(at: i) } else { apply(&n.conclusions[i]) }
            } else if i >= c, i - c < n.todos.count {
                if text.isEmpty { n.todos.remove(at: i - c) } else { apply(&n.todos[i - c]) }
            }
        }
        return n
    }
}

#if !CICADA_IOS
extension AppModel {
    func canEditNotes(_ s: Session) -> Bool {
        s.id != store.liveID && importer.status(of: s) == nil && !(s.notes?.isEmpty ?? true)
    }

    func editHooks(_ s: Session) -> NotesEditHooks? {
        guard canEditNotes(s) else { return nil }
        return NotesEditHooks(
            current: noteEdit?.session == s.id ? noteEdit?.target : nil,
            open: { [weak self] t in self?.noteEdit = t.map { NoteEdit(session: s.id, target: $0) } },
            save: { [weak self] t, text, owner in self?.saveNote(s.id, t, text: text, owner: owner) })
    }

    func saveNote(_ id: String, _ target: NoteEdit.Target, text: String, owner: String?? = nil) {
        guard let notes = store.session(id)?.notes else { return }
        saveEditedNotes(notes.editing(target, text: text, owner: owner), session: id)
        noteEdit = nil
        debugLog("notes edit: saved \(target) in \(id)")
    }
}
#endif
