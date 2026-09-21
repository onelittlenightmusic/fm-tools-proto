import Foundation

/// Where a command goes to be run: the caller, not this process.
///
/// This agent used to run `mywant` itself, and decide for itself what it was
/// allowed to run. Both halves of that were a copy of something the caller
/// already had. The command list came from `mywant commands --json` (see
/// MyWantCLI), but what was safe, what was the board's, and what a person's
/// "はい" looked like were all written again here in Swift — three judgements
/// kept in two languages, already drifting: the two lists of yes-words had
/// stopped agreeing, and the one here let "はい、でも先に天気を見せて" through as
/// consent, which its own comment says is not consent.
///
/// So the running moves to the caller. This writes a line saying what it would
/// run and reads back what happened:
///
///     {"ask":"run","seq":1,"command":"wants list","args":[]}
///       → {"seq":1,"ran":true,"ok":true,"output":"…"}
///
///     {"ask":"run","seq":2,"command":"wants delete","args":["X"]}
///       → {"seq":2,"ran":false,"ok":false,"output":"NOT RUN — waiting for a person …"}
///
/// The second case is the whole point. Nothing here decides it, and nothing
/// here asks the model to decide it either — the `confirmed` flag this tool
/// used to carry was the same model marking its own homework. The caller knows
/// the risk of every command, owns the screen the question appears on, and
/// already has one place where a person's yes lands.
///
/// The answer comes back at once, even when it is "a person is being asked".
/// Waiting here for a human would hold this turn — and a held turn is the
/// deadlock that the handback in MyWantCLI was written to get out of: one
/// conversation with an 8k model waiting inside another.
///
/// Reading stdin from here is safe because a served turn is the only thing
/// happening: serve() is awaiting this call and is not reading. With no caller
/// listening (one-shot `fmtool "question"`), the broker stays off and the tool
/// runs the command itself, as it always did.
actor Broker {
    static let shared = Broker()

    private var listening = false
    private var seq = 0

    /// What came back: whether it ran, whether it worked, and what it printed.
    struct Answer {
        let ran: Bool
        let ok: Bool
        let output: String
    }

    /// Turned on by serve(); off for a one-shot run.
    func listen() { listening = true }

    /// `args` is already split the way this side decided it: a name with a
    /// space in it is one argument ("transit search" is a want, not two
    /// words), so the caller must not split it again.
    func run(command: String, args: [String]) -> Answer? {
        guard listening else { return nil }
        seq += 1
        let request: [String: Any] = [
            "ask": "run", "seq": seq, "command": command, "args": args,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)

        guard let reply = readLine(strippingNewline: true),
              let replyData = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any],
              (object["seq"] as? Int) == seq
        else {
            // No answer, or an answer to something else. Said rather than
            // guessed: a tool that quietly ran the command itself here would
            // be exactly the ungated path this file exists to remove.
            return Answer(ran: false, ok: false, output: "NOT RUN — mywant did not answer.")
        }
        return Answer(
            ran: object["ran"] as? Bool ?? false,
            ok: object["ok"] as? Bool ?? false,
            output: object["output"] as? String ?? ""
        )
    }
}
