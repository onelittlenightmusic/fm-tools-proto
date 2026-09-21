import Foundation

/// A request the agent hands back instead of carrying out.
///
/// Building or finding something on the board takes several commands, and
/// which ones depends on what the earlier ones found. That is worked out by
/// the caller — MyWant's own goal loop, which asks a model one short question
/// at a time and checks every answer against the CLI's own catalogue — not by
/// an 8k model holding the whole job in its head.
///
/// It used to be handed over by running `mywant do`, which made a want of the
/// request: a tile on the board for every question the robot was asked, and a
/// second conversation with the same model started from inside this one, each
/// waiting on the other. Now the tool writes the words down here, the turn
/// ends, and the caller reads them off the reply and does the work itself.
///
/// This file used to hold a second thing: the gate in front of the commands
/// that cannot be taken back. It asked the model to assert that the person had
/// agreed, and then checked the person's own last message to see whether that
/// was true — a model marking its own homework, with a second marker behind
/// it. Both halves are gone. The caller runs every command now (see
/// Broker.swift) and has one place where a yes lands, so there is nothing here
/// to gate and no second list of the ways a person says yes.

actor GoalBox {
    private var pending = ""

    func hand(over words: String) { pending = words }

    /// The request, and the box is empty again: one handover per turn.
    func take() -> String {
        let words = pending
        pending = ""
        return words
    }
}

actor CurrentRequest {
    private var text = ""

    func note(prompt: String) {
        // The first line only: the server appends the asker's position as a
        // context line, which is for the model and not part of what was said.
        text = prompt
            .components(separatedBy: "\n\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func words() -> String { text }
}

/// Whether the person's most recent message was a yes.
///
/// Set from the incoming request (see Serve.swift), not from anything the model
/// produced: it is the one signal in the conversation the model does not write.
